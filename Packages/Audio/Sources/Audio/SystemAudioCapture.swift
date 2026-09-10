//
//  SystemAudioCapture.swift
//  Audio
//
//  System-audio channel = the teammates in the meeting.
//
//  Uses Core Audio process taps instead of ScreenCaptureKit, so capturing the
//  device output does NOT start a screen recording: there is no purple
//  screen-sharing indicator and DRM-protected playback (Netflix, Disney+, …)
//  keeps working while we record.
//
//  Pipeline: process tap -> private aggregate device -> IO proc -> resample
//  to 16 kHz mono Float32.
//
//  Two tap shapes: the default *global* tap hears everything the Mac plays,
//  and a *scoped* tap hears only one app — the include set of its process
//  objects, resolved by the pure `ScopedProcessResolution` and followed live
//  as helpers appear and vanish. Everything after the tap is identical in
//  both shapes. A scoped session runs a second, global instance of this class
//  whose samples feed only the AEC's far-end reference; nothing in here knows
//  about that, and the AEC never writes back into this stream.
//
//  Isolation (ADR-002). v1 compiled this class as implicitly `@MainActor`
//  while documenting an "everything mutates on ioQueue" invariant that
//  `activate()` and `stop()` violated from the main actor. Here the state is
//  split by who touches it and each half is behind its own lock, which makes
//  the invariant enforceable rather than documented:
//
//    * `io` holds the format/resampler pair, the rate guard and the delivery
//      counters. The IO proc takes it once per cycle and holds it for the
//      duration of one resample. Nothing slow is ever done under it.
//    * `topology` holds the Core Audio object ids, the listener blocks and
//      the scoped-follow state. Bring-up, teardown and follow updates take
//      it, and those do call into Core Audio — which is exactly why it is a
//      separate lock: a property write that takes milliseconds must not
//      stall an IO cycle that is due every ~10.7 ms.
//
//  Two locks, never nested: a path that needs both (the format refresh) reads
//  the object id out of `topology`, releases it, and then takes `io`.
//
//  One of the two files in this package that may import AppKit, for process
//  identity only (scripts/check_boundaries.sh allowlists it by path).
//

import AVFoundation
import AppKit
import CoreAudio
import EchoCore
import Synchronization
import os

public final class SystemAudioCapture: Sendable {

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "SystemAudioCapture")

    /// Which process objects a scoped tap actually includes, per app family.
    /// Watch with:
    ///
    ///     log stream --predicate 'subsystem == "com.sancrisoft.Echo"
    ///         && category == "ScopedCapture"' --level info
    private static let scopeLog = Logger(subsystem: AppIdentity.logSubsystem, category: "ScopedCapture")

    public enum CaptureError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case tapFormatUnavailable
        case aggregateCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)
        /// Any failure to establish the *scoped* topology at start. Distinct
        /// so Recording can catch exactly this and fall back to a global
        /// session — the fallback itself lives there, not here, and it is
        /// visible: the session reports "Everything".
        case scopedTapFailed(underlying: any Error)

        public var errorDescription: String? {
            switch self {
            case .tapCreationFailed:
                return "Couldn't capture system audio."
            case .tapFormatUnavailable:
                return "Couldn't read the system audio format."
            case .aggregateCreationFailed:
                return "Couldn't create the system audio capture device."
            case .ioProcFailed:
                return "Couldn't start system audio capture."
            case .scopedTapFailed:
                return "Couldn't capture the selected app's audio."
            }
        }
    }

    /// What the tap really delivered this session, for the stop-time
    /// accounting. `nil` when it never came up.
    public struct DeliveryStats: Sendable {
        public var cycles: Int
        public var emptyCycles: Int
        public var frames: Int
        public var sampleRate: Double
        public var uptimeSeconds: TimeInterval
        /// Cycle boundaries where more than one cycle's worth of time passed.
        public var skips: Int
        public var secondsLostToSkips: TimeInterval
        /// Of that, what sat in gaps of 100 ms or more — the signature of a
        /// tap that stopped calling rather than cycles we arrived late for.
        public var secondsLostToLongGaps: TimeInterval
        public var longestGapSeconds: TimeInterval
        /// Rate-guard state: windows judged, the last rate measured, and the
        /// rate the tap is currently believed to run at.
        public var rateConclusions: Int
        public var measuredRate: Double
        public var declaredRate: Double

        /// Seconds of audio actually handed over, at the tap's own rate.
        public var deliveredSeconds: TimeInterval {
            sampleRate > 0 ? Double(frames) / sampleRate : 0
        }

        /// Seconds the cycles themselves account for — delivered audio plus
        /// what the empty ones would have carried. If this lands near uptime
        /// the tap simply had nothing to give; if it lands short, cycles are
        /// being dropped.
        public var cycleCoverageSeconds: TimeInterval {
            let delivering = cycles - emptyCycles
            guard delivering > 0 else { return 0 }
            return deliveredSeconds / Double(delivering) * Double(cycles)
        }
    }

    // MARK: - State

    /// Everything the IO proc touches. Reset per activation, never in
    /// `stop()`, so the session teardown can still read the counters.
    ///
    /// `@unchecked Sendable` because it holds `AVAudioFormat` and
    /// `BufferResampler`, neither of which is `Sendable`, and Swift cannot
    /// see that the `io` lock is the only way in. The threads it is reached
    /// from are: the Core Audio IO queue (`handle`, every ~10.7 ms), the same
    /// queue via the format listeners (`refreshTapFormat`, `adopt`), and
    /// whichever context Recording calls `start`/`stop`/`deliveryStats` from.
    /// Every one of those goes through `io.withLock`; nothing here is read or
    /// written outside it.
    private struct IOState: @unchecked Sendable {
        var resampler: BufferResampler?
        var tapFormat: AVAudioFormat?

        /// Sample-rate truth. The rate read at start is a claim, not a fact:
        /// a Bluetooth headset switching into its call mode drops the output
        /// device to 24 kHz while macOS keeps reporting 48 kHz for a while,
        /// and a resampler built on that claim halves the audio's duration —
        /// the double-speed Others channel. Three defences, cheapest first:
        ///
        ///   1. `rateGuard` — every buffer is weighed against the wall clock,
        ///      so a lying rate is caught from the audio itself.
        ///   2. the format listeners — macOS's own late correction, taken the
        ///      moment it arrives instead of being ignored.
        ///   3. a rebuild on output-device change, driven from Recording: the
        ///      aggregate is anchored to one device and cannot follow.
        ///
        /// All three converge on `adopt(format:reason:)`.
        var rateGuard: CaptureRateGuard?

        /// Rates this tap was measured to NOT be running at. Without this the
        /// defences fight each other: a spurious notification re-reads the
        /// same stale rate the audio already disproved, defence 1 disproves
        /// it again two seconds later, and the flip-flop eats the correction
        /// budget until the lie wins. Measurement outranks the claim — and if
        /// the hardware really does return to a discredited rate, defence 1
        /// measures its way back to it.
        var discreditedRates: Set<Double> = []

        /// One trace per capture instance: a device that keeps lying should
        /// not write a trace every two seconds.
        var rateCorrectionTraced = false
        var didLogRateMeasurement = false
        var didLogFirstBuffer = false

        /// When this tap's bring-up began, so the first delivered buffer can
        /// report how long the Others channel was actually deaf.
        var activatedAt: ContinuousClock.Instant?

        /// IO-proc accounting. The tap delivers measurably less audio than
        /// the meeting lasts (8 % on a real call, with nothing lost
        /// downstream — the writer's counters clear the ingest chain), and
        /// only two shapes explain that: cycles that fire with an empty
        /// buffer (the tap idle because nothing is rendering) or cycles that
        /// never fire at all (Core Audio dropping them because this block ran
        /// over its ~11.6 ms budget). The counters tell them apart.
        var cycles = 0
        var emptyCycles = 0
        var deliveredFrames = 0

        /// How many observation windows the rate guard actually reached a
        /// verdict on, and what the last one measured. Zero conclusions on a
        /// session that still came out short would mean the guard is being
        /// starved by its own continuity check — the one remaining way this
        /// can fail silently, and not something to find out by reasoning
        /// about it.
        var rateConclusions = 0
        var lastMeasuredRate: Double = 0

        /// The *shape* of the loss, which the totals can't show: scattered
        /// single skips mean cycles we failed to be ready for, while a few
        /// long gaps mean the tap itself went quiet and never called. The two
        /// need opposite fixes — schedule better, or declare the silence as a
        /// gap.
        var lastCycleAt: ContinuousClock.Instant?
        var skippedCycles = 0
        var secondsLostToSkips: TimeInterval = 0
        var secondsLostToLongGaps: TimeInterval = 0
        var longestGapSeconds: TimeInterval = 0

        mutating func resetCounters() {
            cycles = 0
            emptyCycles = 0
            deliveredFrames = 0
            lastCycleAt = nil
            rateConclusions = 0
            lastMeasuredRate = 0
            skippedCycles = 0
            secondsLostToSkips = 0
            secondsLostToLongGaps = 0
            longestGapSeconds = 0
        }
    }

    /// The Core Audio objects and the listeners hanging off them, plus the
    /// scoped-follow state. `nil`/empty for a global session.
    ///
    /// `@unchecked Sendable` for the same reason as `IOState`: it holds a
    /// `CATapDescription` and two listener blocks, none of them `Sendable`.
    /// The threads it is reached from are: the scope queue (the process-list
    /// listener and its coalesced follow update), the IO queue (the format
    /// listeners, which read `tapID` only), and the caller's context for
    /// bring-up and teardown. Every one goes through `topology.withLock`.
    private struct Topology: @unchecked Sendable {
        var tapID: AudioObjectID?
        var aggregateID: AudioObjectID?
        var ioProcID: AudioDeviceIOProcID?

        var formatListenerBlock: AudioObjectPropertyListenerBlock?
        var formatListenerTapID: AudioObjectID?
        var formatListenerDeviceID: AudioObjectID?

        /// The description object is kept because updating a live tap means
        /// writing a *description* back to `kAudioTapPropertyDescription` —
        /// mutating this one preserves the UUID the aggregate device
        /// references the tap by.
        var scopedApp: ProcessSelector?
        var scopedDescription: CATapDescription?
        var includedObjects: Set<AudioObjectID> = []
        var followBlock: AudioObjectPropertyListenerBlock?
        /// True while a coalesced follow rescan is already scheduled.
        var followRescanPending = false
        /// True once the current follow-failure burst has been traced, so a
        /// flood of process-list changes against a wedged tap records one
        /// trace, not one per change. Reset by the next successful update.
        var followFailureTraced = false
    }

    private let io = Mutex(IOState())
    private let topology = Mutex(Topology())

    /// 16 kHz mono Float32 frames. Invoked on `ioQueue`.
    private let onSamples: (@Sendable ([Float]) -> Void)?

    /// Normalized loudness (0...1). Invoked on `ioQueue`.
    private let onLevel: (@Sendable (Double) -> Void)?

    /// `.userInteractive` on purpose: Core Audio hands this queue an IO cycle
    /// every ~10.7 ms and skips the cycle outright if the block has not been
    /// scheduled by the time the next one is due — the tap loses ~8 % of a
    /// real meeting that way, and the work inside the block is measured at
    /// 0.1 % of the budget, so the loss is in *reaching* the block, not
    /// running it. An unspecified-QoS queue competes with everything else on
    /// the box; this one is scheduled like the interaction it is.
    private let ioQueue = DispatchQueue(label: "com.sancrisoft.Echo.systemAudio", qos: .userInteractive)

    /// Where the process-list listener fires and where a follow update is
    /// applied. v1 used the main queue, an artefact of its main-actor default
    /// isolation; Core Audio property reads and writes are not main-thread
    /// bound, and an engine package has no business scheduling work on the
    /// UI's queue. Serial, so a coalesced rescan cannot overlap another.
    private let scopeQueue = DispatchQueue(label: "com.sancrisoft.Echo.systemAudio.scope")

    private static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    public init(
        onSamples: (@Sendable ([Float]) -> Void)? = nil,
        onLevel: (@Sendable (Double) -> Void)? = nil
    ) {
        self.onSamples = onSamples
        self.onLevel = onLevel
    }

    public func deliveryStats() -> DeliveryStats? {
        io.withLock { state in
            guard let activatedAt = state.activatedAt, let tapFormat = state.tapFormat else { return nil }
            return DeliveryStats(
                cycles: state.cycles,
                emptyCycles: state.emptyCycles,
                frames: state.deliveredFrames,
                sampleRate: tapFormat.sampleRate,
                uptimeSeconds: Self.milliseconds(activatedAt.duration(to: .now)) / 1_000,
                skips: state.skippedCycles,
                secondsLostToSkips: state.secondsLostToSkips,
                secondsLostToLongGaps: state.secondsLostToLongGaps,
                longestGapSeconds: state.longestGapSeconds,
                rateConclusions: state.rateConclusions,
                measuredRate: state.lastMeasuredRate,
                declaredRate: state.rateGuard?.declaredRate ?? tapFormat.sampleRate
            )
        }
    }

    // MARK: - Lifecycle

    /// Raises macOS's "System Audio Recording" permission prompt ahead of the
    /// first real session. The prompt fires when a process tap actually runs,
    /// so this starts a throwaway capture (no callbacks wired) and tears it
    /// down immediately. Denial is not an error here — the real session start
    /// surfaces its own failure.
    public static func primePermission() async {
        let probe = SystemAudioCapture()
        do {
            try probe.start()
        } catch {
            Self.log.warning(
                """
                System-audio permission probe failed: \(error.localizedDescription, privacy: .public)
                """
            )
        }
        probe.stop()
    }

    /// Starts capture with the given system-channel coverage. `.everything`
    /// is the global tap; `.app` taps only that app's current process objects
    /// and follows the set live. Any scoped-start failure surfaces as
    /// `CaptureError.scopedTapFailed` so Recording can fall back to a global
    /// session.
    public func start(scope: CaptureScope = .everything) throws {
        switch scope {
        case .everything:
            try startGlobal()
        case .app(let app):
            do {
                try startScoped(to: app)
            } catch {
                // Unwind whatever half-built topology exists so the caller's
                // global fallback starts from a clean slate.
                stop()
                throw CaptureError.scopedTapFailed(underlying: error)
            }
        }
    }

    private func startGlobal() throws {
        // A global tap of every process's output, mixed to mono. The empty
        // exclude-list means "tap everything"; Echo plays no audio of its own.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "Echo System Tap"
        description.muteBehavior = .unmuted  // don't silence what the user hears
        description.isPrivate = true
        // NOTE: do NOT touch `isExclusive`. The global-tap initializer sets it
        // to true ("exclude the listed PIDs"); flipping it inverts to "include
        // only the listed PIDs" (none) and the tap delivers pure silence.

        try activate(description)
    }

    /// The scoped topology: resolve the app's process objects, tap exactly
    /// those, then follow the set as helpers appear and vanish. An empty
    /// include set is legal at every point — verified empirically: Core Audio
    /// accepts an empty-set tap at creation, so there is no lazy arming; the
    /// tap simply delivers nothing until the set grows.
    private func startScoped(to app: ProcessSelector) throws {
        let processes = Self.scopedProcessCandidates()
        let include = ScopedProcessResolution.includeSet(for: app, in: processes.map(\.entry))

        // Mono mixdown of exactly the included process objects. This
        // initializer sets `isExclusive` to false ("include only the listed
        // objects") — the correct sense here; see the global path's warning
        // before considering touching it.
        let description = CATapDescription(monoMixdownOfProcesses: include.sorted())
        description.name = "Echo Scoped System Tap"
        description.muteBehavior = .unmuted  // don't silence what the user hears
        description.isPrivate = true

        try activate(description)

        topology.withLock { state in
            state.scopedApp = app
            state.scopedDescription = description
            state.includedObjects = include
        }
        try armFollowListener()

        #if DEBUG
            Self.logScope("start", app: app, included: processes.filter { include.contains($0.entry.object) })
        #endif
    }

    /// Tap -> aggregate -> IO proc -> running, shared by both tap shapes.
    ///
    /// Every step is timed. Bringing this path up costs the Others channel
    /// its first seconds of the meeting (the mic is already recording by
    /// then, so the hole is declared as a capture gap by Recording), and the
    /// only way to know whether pre-warming it would win those seconds back
    /// is to know which step actually spends them — creating the tap,
    /// creating the aggregate, or starting the device. Logged at `notice` so
    /// the answer survives in the system log for reading after the meeting,
    /// not only in a live `log stream`.
    private func activate(_ description: CATapDescription) throws {
        let broughtUpAt = ContinuousClock.now
        var mark = broughtUpAt

        /// Milliseconds since the previous mark.
        func step() -> Double {
            let now = ContinuousClock.now
            defer { mark = now }
            return Self.milliseconds(mark.duration(to: now))
        }

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        let tapMilliseconds = step()
        Self.log.info("CreateProcessTap status=\(tapStatus, privacy: .public) tapID=\(tap, privacy: .public)")
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        topology.withLock { $0.tapID = tap }

        guard let format = Self.readTapFormat(tap) else { throw CaptureError.tapFormatUnavailable }

        // Reset and arm the IO state before the IO proc can possibly fire,
        // not after.
        io.withLock { state in
            state.resetCounters()
            state.tapFormat = format
            state.resampler = BufferResampler(from: format)
            state.rateGuard = CaptureRateGuard(declaredRate: format.sampleRate)
        }
        Self.log.info(
            """
            System tap format: \(format.channelCount, privacy: .public) ch @ \
            \(format.sampleRate, privacy: .public) Hz
            """
        )

        // Wrap the tap in a private aggregate device so we can run an IO proc.
        let outputUID = Self.defaultOutputDeviceUID()
        Self.log.info("Default output device UID: \(outputUID ?? "nil", privacy: .public)")

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            Self.aggregateDescription(tapUID: description.uuid.uuidString, outputUID: outputUID) as CFDictionary,
            &aggregate
        )
        let aggregateMilliseconds = step()
        Self.log.info(
            "CreateAggregateDevice status=\(aggregateStatus, privacy: .public) aggID=\(aggregate, privacy: .public)"
        )
        guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
            throw CaptureError.aggregateCreationFailed(aggregateStatus)
        }
        topology.withLock { $0.aggregateID = aggregate }

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            // The capture timestamp was already being handed to us and thrown
            // away; it is the second clock the rate guard needs.
            self?.handle(inInputData, inputTime: inInputTime)
        }
        let procMilliseconds = step()
        guard procStatus == noErr, let proc else {
            ErrorTrace.record(
                "CreateIOProcID failed",
                category: "SystemAudioCapture",
                metadata: ["status": String(procStatus)]
            )
            throw CaptureError.ioProcFailed(procStatus)
        }
        topology.withLock { $0.ioProcID = proc }

        let startStatus = AudioDeviceStart(aggregate, proc)
        let startMilliseconds = step()
        Self.log.info("AudioDeviceStart status=\(startStatus, privacy: .public)")
        guard startStatus == noErr else { throw CaptureError.ioProcFailed(startStatus) }

        armFormatListeners(tap: tap)
        io.withLock { $0.activatedAt = broughtUpAt }
        Self.log.notice(
            """
            System tap brought up in \
            \(Self.milliseconds(broughtUpAt.duration(to: .now)), format: .fixed(precision: 0), privacy: .public) ms \
            (tap \(tapMilliseconds, format: .fixed(precision: 0), privacy: .public) / \
            aggregate \(aggregateMilliseconds, format: .fixed(precision: 0), privacy: .public) / \
            ioproc \(procMilliseconds, format: .fixed(precision: 0), privacy: .public) / \
            start \(startMilliseconds, format: .fixed(precision: 0), privacy: .public))
            """
        )
    }

    public func stop() {
        let torn = topology.withLock { state -> Topology in
            let previous = state
            state = Topology()
            return previous
        }

        if let followBlock = torn.followBlock {
            var address = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, scopeQueue, followBlock
            )
        }
        Self.disarmFormatListeners(torn, queue: ioQueue)

        if let aggregateID = torn.aggregateID, let ioProcID = torn.ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if let aggregateID = torn.aggregateID { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if let tapID = torn.tapID { AudioHardwareDestroyProcessTap(tapID) }

        io.withLock { state in
            state.resampler = nil
            state.tapFormat = nil
            state.rateGuard = nil
            state.rateCorrectionTraced = false
            state.discreditedRates = []
            state.didLogFirstBuffer = false
            state.didLogRateMeasurement = false
            state.activatedAt = nil
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    // MARK: - Scope follow

    /// One process object as enumerated for scoping. `pid` exists only for
    /// the DEBUG scope log; the resolver decides on `entry` alone.
    private struct ScopedProcessCandidate {
        var pid: pid_t
        var entry: ScopedProcessResolution.ProcessEntry
    }

    /// The follow listener could not be registered — surfaced through
    /// `CaptureError.scopedTapFailed` as its underlying reason.
    private struct FollowListenerRegistrationFailed: Error {
        let status: OSStatus
    }

    /// Watches the process-object list so helpers spawning (or dying)
    /// mid-session reach the live tap. Registration failure is a scoped-start
    /// failure, not a degraded success: a scoped tap that cannot follow would
    /// silently drop a mid-call helper's audio — the failure shape scoping
    /// exists to prevent — where the caller's global fallback only ever
    /// over-records, visibly.
    private func armFollowListener() throws {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleFollowUpdate()
        }
        var address = Self.processListAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, scopeQueue, block
        )
        guard status == noErr else {
            ErrorTrace.record(
                "Scoped-capture process-list listener registration failed",
                category: "ScopedCapture",
                metadata: ["status": String(status)]
            )
            throw FollowListenerRegistrationFailed(status: status)
        }
        topology.withLock { $0.followBlock = block }
    }

    /// Collapses a burst of process-list notifications into one
    /// re-resolution: one real event (an app launching helpers) arrives as
    /// several notifications, and each rescan reads two properties per
    /// process.
    private func scheduleFollowUpdate() {
        let alreadyPending = topology.withLock { state -> Bool in
            defer { state.followRescanPending = true }
            return state.followRescanPending
        }
        guard !alreadyPending else { return }

        scopeQueue.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            guard let self else { return }
            self.topology.withLock { $0.followRescanPending = false }
            self.applyFollowUpdateIfNeeded()
        }
    }

    /// Re-resolves the app's process set and, only when it genuinely changed,
    /// writes the new include set to the LIVE tap through
    /// `kAudioTapPropertyDescription` — verified empirically to accept both
    /// growing and shrinking sets without tearing the tap down. On a failed
    /// write the last successfully applied set stays in force: a running
    /// scoped session never silently widens; the next process-list change
    /// retries against fresh truth.
    private func applyFollowUpdateIfNeeded() {
        // Read the current intent out under the lock, then do the Core Audio
        // work outside it — the write below can take milliseconds.
        let current = topology.withLock {
            state -> (ProcessSelector, CATapDescription, AudioObjectID, Set<AudioObjectID>)? in
            guard let app = state.scopedApp,
                let description = state.scopedDescription,
                let tapID = state.tapID,
                state.followBlock != nil  // a coalesced rescan can land after stop()
            else { return nil }
            return (app, description, tapID, state.includedObjects)
        }
        guard let (app, description, tapID, includedObjects) = current else { return }

        let processes = Self.scopedProcessCandidates()
        guard
            let newSet = ScopedProcessResolution.followUpdate(
                for: app, current: includedObjects, processes: processes.map(\.entry)
            )
        else { return }

        description.processes = newSet.sorted()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var box: CATapDescription? = description
        let status = withUnsafeMutablePointer(to: &box) {
            AudioObjectSetPropertyData(
                tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription?>.size), $0
            )
        }
        guard status == noErr else {
            // Keep the description object telling the truth about the tap.
            description.processes = includedObjects.sorted()
            let shouldTrace = topology.withLock { state -> Bool in
                guard !state.followFailureTraced else { return false }
                state.followFailureTraced = true
                return true
            }
            if shouldTrace {
                ErrorTrace.record(
                    "Scoped tap include-set update failed; keeping last-good set",
                    category: "ScopedCapture",
                    metadata: [
                        "status": String(status),
                        "app": app.displayName,
                        "lastGoodCount": String(includedObjects.count),
                        "rejectedCount": String(newSet.count),
                    ]
                )
            }
            return
        }
        topology.withLock { state in
            state.includedObjects = newSet
            state.followFailureTraced = false
        }

        #if DEBUG
            Self.logScope("follow", app: app, included: processes.filter { newSet.contains($0.entry.object) })
        #endif
    }

    /// Every process object the audio server knows about, with its bundle
    /// identity — including the `NSRunningApplication` fallback for helpers
    /// Core Audio reports no bundle ID for. An object whose pid is unreadable
    /// is skipped: it died between the list read and this call, and the next
    /// listener fire brings the truth. A failed list read yields the empty
    /// list, which resolves to the legal empty set (silence) rather than an
    /// error.
    private static func scopedProcessCandidates() -> [ScopedProcessCandidate] {
        var address = Self.processListAddress
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
            ) == noErr, size > 0
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects
            ) == noErr
        else { return [] }

        return objects.compactMap { object in
            guard let pid = pid(of: object) else { return nil }
            return ScopedProcessCandidate(
                pid: pid,
                entry: .init(
                    object: object,
                    bundleID: bundleID(of: object, pid: pid),
                    // The second identity, for the helpers whose bundle ID
                    // shares no prefix with their parent app (Firefox's and
                    // Zen's media processes). One cheap syscall per process;
                    // the Info.plist read behind it is cached per app bundle,
                    // which is what keeps a follow update over every process
                    // object affordable — measured over this machine's full
                    // process table (204 processes): 7 ms cold, 1 ms warm,
                    // against an 80 ms debounce.
                    appBundleID: AppBundleIdentity.appBundleID(ofPID: pid)
                )
            )
        }
    }

    private static func pid(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr else {
            return nil
        }
        return pid
    }

    /// The process's bundle ID, or `""` when it has none. Core Audio reports
    /// nothing for some helpers; `NSRunningApplication` still knows anything
    /// the user could have launched. True daemons stay empty — and an empty
    /// ID never matches any app, so they can never join a scoped tap.
    private static func bundleID(of object: AudioObjectID, pid: pid_t) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
            let value
        {
            let bundleID = value.takeRetainedValue() as String
            if !bundleID.isEmpty { return bundleID }
        }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    }

    #if DEBUG
        /// The scope log itself: which process objects the scoped tap includes
        /// right now, per app family. Process identity only — no audio, ever.
        private static func logScope(_ phase: String, app: ProcessSelector, included: [ScopedProcessCandidate]) {
            let rows =
                included
                .sorted { $0.pid < $1.pid }
                .map { "pid=\($0.pid) bundle=\($0.entry.bundleID.isEmpty ? "<none>" : $0.entry.bundleID)" }
            let detail =
                rows.isEmpty
                ? "no matching processes (silence until the app plays)"
                : rows.joined(separator: " | ")
            Self.scopeLog.info(
                """
                scope \(phase, privacy: .public): app=\(app.displayName, privacy: .public) \
                include(\(included.count, privacy: .public)) — \(detail, privacy: .public)
                """
            )
        }
    #endif

    // MARK: - IO

    /// One IO cycle. Runs on `ioQueue`; takes the `io` lock once and does
    /// nothing slow under it.
    private func handle(
        _ bufferList: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let stamp = inputTime.pointee
        let deviceSampleTime = stamp.mFlags.contains(.sampleTimeValid) ? stamp.mSampleTime : nil

        // Everything the cycle decides, decided under one lock; the callbacks
        // and the format adoption happen after it is released.
        enum Outcome {
            case idle
            case delivered(frames: [Float], correction: Double?)
        }

        var firstBufferLog: (buffers: Int, channels: UInt32, bytes: UInt32, sinceBringUp: Double?)?
        var rateArmedLog: (declared: Double, measured: Double)?
        var rateTrace: (declared: Double, measured: Double, adopted: Double?)?

        let outcome: Outcome = io.withLock { state in
            state.cycles += 1
            guard let tapFormat = state.tapFormat, let resampler = state.resampler else { return .idle }

            if !state.didLogFirstBuffer {
                state.didLogFirstBuffer = true
                let first = buffers.first
                // Shape only. v1 also logged the buffer's peak magnitude,
                // computed by a loop over every sample inside the IO cycle:
                // that is audio content in a log (only ids, formats, rates
                // and times may be logged) and it is work in the one place
                // measured to cost a meeting 8 % when the cycle is missed.
                firstBufferLog = (
                    buffers: buffers.count,
                    channels: first?.mNumberChannels ?? 0,
                    bytes: first?.mDataByteSize ?? 0,
                    sinceBringUp: state.activatedAt.map { Self.milliseconds($0.duration(to: .now)) }
                )
            }

            // Only the first buffer is read, which is correct because both
            // tap shapes are created as a MONO MIXDOWN — one buffer, one
            // channel. A multi-buffer (deinterleaved multi-channel) tap
            // would need this loop widened; nothing here may create one
            // without changing this.
            guard let first = buffers.first, let data = first.mData else {
                state.emptyCycles += 1
                return .idle
            }

            let bytesPerFrame = max(1, Int(tapFormat.streamDescription.pointee.mBytesPerFrame))
            let frameCount = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
            guard frameCount > 0 else {
                state.emptyCycles += 1
                return .idle
            }
            state.deliveredFrames += Int(frameCount)
            Self.noteCycleInterval(&state, carrying: Int(frameCount), at: tapFormat.sampleRate)

            guard let pcm = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frameCount),
                let destination = pcm.floatChannelData?[0]
            else { return .idle }

            pcm.frameLength = frameCount
            memcpy(destination, data, Int(first.mDataByteSize))

            guard let frames = resampler.resample(pcm) else { return .idle }

            // Defence 1: weigh what the tap actually delivered against the
            // wall clock, and correct the declared rate when they disagree.
            // Two additions and a comparison per buffer; silent unless a
            // window of continuous audio contradicts the rate the tap claims.
            var correction: Double?
            if let verdict = state.rateGuard?.observe(
                frames: Int(frameCount), deviceSampleTime: deviceSampleTime, at: .now
            ) {
                if let measured = verdict.measuredRate {
                    state.rateConclusions += 1
                    state.lastMeasuredRate = measured
                }

                // One line per session the first time a window is actually
                // judged. Without it a guard that never judges — a device
                // publishing no valid sample clock, a tap that only delivers
                // in bursts — would be indistinguishable from a guard that
                // judged and found nothing wrong.
                if case .measuring = verdict {
                } else if !state.didLogRateMeasurement {
                    state.didLogRateMeasurement = true
                    rateArmedLog = (
                        declared: state.rateGuard?.declaredRate ?? 0,
                        measured: verdict.measuredRate ?? 0
                    )
                }

                if case .mismatch(let measured) = verdict {
                    let corrected = CaptureRateGuard.snapped(measured)
                    let declared = state.rateGuard?.declaredRate ?? 0
                    if state.rateGuard?.canCorrect == true {
                        if !state.rateCorrectionTraced {
                            state.rateCorrectionTraced = true
                            rateTrace = (declared: declared, measured: measured, adopted: corrected)
                        }
                        state.discreditedRates.insert(declared)
                        // Adopt even if rebuilding the converter fails:
                        // leaving the guard pointed at a rate we know is
                        // wrong would re-fire every window.
                        state.rateGuard?.noteCorrection(to: corrected)
                        correction = corrected
                    } else if !state.rateCorrectionTraced {
                        state.rateCorrectionTraced = true
                        rateTrace = (declared: declared, measured: measured, adopted: nil)
                    }
                }
            }
            return .delivered(frames: frames, correction: correction)
        }

        if let firstBufferLog {
            Self.log.info(
                """
                IO proc fired: \(firstBufferLog.buffers, privacy: .public) buffer(s), \
                ch=\(firstBufferLog.channels, privacy: .public), \
                bytes=\(firstBufferLog.bytes, privacy: .public)
                """
            )
            if let sinceBringUp = firstBufferLog.sinceBringUp {
                Self.log.notice(
                    """
                    First system buffer \(sinceBringUp, format: .fixed(precision: 0), privacy: .public) ms \
                    after bring-up began
                    """
                )
            }
        }
        if let rateArmedLog {
            // `notice`, not `info`: this one is read after the fact, and info
            // never reaches the persistent log.
            Self.log.notice(
                """
                System tap rate check armed: declared \(rateArmedLog.declared, privacy: .public) Hz, \
                delivering \(rateArmedLog.measured, privacy: .public) Hz
                """
            )
        }
        if let rateTrace {
            ErrorTrace.record(
                "System tap sample rate disagreed with delivered audio",
                category: "SystemAudioCapture",
                metadata: [
                    "declaredHz": String(format: "%.0f", rateTrace.declared),
                    "measuredHz": String(format: "%.1f", rateTrace.measured),
                    "adoptedHz": rateTrace.adopted.map { String(format: "%.0f", $0) }
                        ?? "none (correction budget spent)",
                ]
            )
        }

        guard case .delivered(let frames, let correction) = outcome else { return }
        onLevel?(AudioLevelMeter.level(from: frames))
        onSamples?(frames)

        // Last, so a correction takes effect from the next buffer rather than
        // swapping the converter this one is still using.
        if let correction {
            Self.log.warning(
                """
                System tap delivers a rate its format denied — adopting \
                \(correction, privacy: .public) Hz
                """
            )
            adoptSampleRate(correction, reason: "measured delivery")
        }
    }

    /// Measures the wall time between consecutive cycles against the audio
    /// each one carries. An interval longer than the audio it delivered means
    /// time passed that no cycle covered — and the distribution of those
    /// intervals is what says whether we missed cycles or were never called.
    private static func noteCycleInterval(_ state: inout IOState, carrying frames: Int, at rate: Double) {
        let now = ContinuousClock.now
        defer { state.lastCycleAt = now }
        guard let last = state.lastCycleAt, rate > 0 else { return }

        let cycleSeconds = Double(frames) / rate
        let interval = Self.milliseconds(last.duration(to: now)) / 1_000
        state.longestGapSeconds = max(state.longestGapSeconds, interval)
        // Half a cycle of slack: normal jitter is not a skip.
        guard interval > cycleSeconds * 1.5 else { return }
        state.skippedCycles += 1
        let lost = interval - cycleSeconds
        state.secondsLostToSkips += lost
        if interval >= 0.1 { state.secondsLostToLongGaps += lost }
    }

    /// Re-labels the incoming audio at `rate`, keeping every other field of
    /// the tap's format. The samples themselves are fine — only the rate they
    /// were filed under was wrong — so this is lossless and gapless: no tap
    /// teardown, no hole in the Others channel.
    private func adoptSampleRate(_ rate: Double, reason: String) {
        guard let current = io.withLock({ $0.tapFormat }), current.sampleRate != rate else { return }
        var asbd = current.streamDescription.pointee
        asbd.mSampleRate = rate
        guard let corrected = AVAudioFormat(streamDescription: &asbd) else { return }
        adopt(format: corrected, reason: reason)
    }

    /// The single place the format/resampler pair changes after start. Both
    /// halves move together under the `io` lock, so the IO proc can never
    /// read one without the other.
    private func adopt(format: AVAudioFormat, reason: String) {
        guard let rebuilt = BufferResampler(from: format) else {
            ErrorTrace.record(
                "Couldn't rebuild the system-audio resampler for a corrected format",
                category: "SystemAudioCapture",
                metadata: ["sampleRate": String(format: "%.0f", format.sampleRate), "reason": reason]
            )
            return
        }
        io.withLock { state in
            state.tapFormat = format
            state.resampler = rebuilt
        }
        Self.log.info(
            """
            System tap format adopted (\(reason, privacy: .public)): \
            \(format.channelCount, privacy: .public) ch @ \(format.sampleRate, privacy: .public) Hz
            """
        )
    }

    // MARK: - Format changes (defence 2)

    /// Listens for the format correction macOS itself publishes — the one the
    /// AirPods defect eventually sends and that reading the format once can
    /// never see. Registered on the tap (its own format property) and on the
    /// output device that clocks it (stream format and nominal rate), because
    /// which of the three fires is device-dependent; they all lead to the
    /// same idempotent re-read. Registered directly on `ioQueue`, where every
    /// format mutation is serialized.
    private func armFormatListeners(tap: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshTapFormat(reason: "macOS format-change notification")
        }
        topology.withLock { $0.formatListenerBlock = block }

        var tapAddress = Self.tapFormatAddress
        if AudioObjectAddPropertyListenerBlock(tap, &tapAddress, ioQueue, block) == noErr {
            topology.withLock { $0.formatListenerTapID = tap }
        }

        guard let deviceID = DefaultAudioDevices.outputDeviceID() else { return }
        var attached = false
        for address in Self.deviceFormatAddresses {
            var address = address
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, ioQueue, block) == noErr {
                attached = true
            }
        }
        if attached { topology.withLock { $0.formatListenerDeviceID = deviceID } }
    }

    private static func disarmFormatListeners(_ torn: Topology, queue: DispatchQueue) {
        guard let block = torn.formatListenerBlock else { return }
        if let tap = torn.formatListenerTapID {
            var address = Self.tapFormatAddress
            AudioObjectRemovePropertyListenerBlock(tap, &address, queue, block)
        }
        if let deviceID = torn.formatListenerDeviceID {
            for address in Self.deviceFormatAddresses {
                var address = address
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
            }
        }
    }

    /// Re-reads the tap's format and adopts it when it genuinely changed.
    /// Idempotent by design: the three listeners routinely fire together for
    /// one real event, and a `stop()` racing a queued notification lands on
    /// the `tapID` guard (a destroyed object simply fails the read).
    private func refreshTapFormat(reason: String) {
        // `topology` first and released before `io` is taken: the two locks
        // are never held together.
        guard let tapID = topology.withLock({ $0.tapID }) else { return }
        guard let current = io.withLock({ $0.tapFormat }), let fresh = Self.readTapFormat(tapID) else { return }
        guard
            fresh.sampleRate != current.sampleRate
                || fresh.channelCount != current.channelCount
        else { return }
        guard !io.withLock({ $0.discreditedRates.contains(fresh.sampleRate) }) else {
            Self.log.info(
                """
                Ignoring a re-declared \(fresh.sampleRate, privacy: .public) Hz — the delivered \
                audio already disproved it
                """
            )
            return
        }

        adopt(format: fresh, reason: reason)
        // The guard now measures against the freshly declared rate; if this
        // one is a lie too, defence 1 catches it two seconds later.
        io.withLock { $0.rateGuard = CaptureRateGuard(declaredRate: fresh.sampleRate) }
    }

    // MARK: - Core Audio helpers

    private static func aggregateDescription(tapUID: String, outputUID: String?) -> [String: Any] {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Echo System Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        // Anchor the aggregate's clock to the current output device.
        if let outputUID {
            description[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        return description
    }

    private static let tapFormatAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// The two properties an output device changes its rate through. Both are
    /// watched: `NominalSampleRate` is the one a device advertises, and
    /// `StreamFormat` is the one the AirPods defect eventually corrects.
    private static let deviceFormatAddresses = [
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
    ]

    private static func readTapFormat(_ tap: AudioObjectID) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = Self.tapFormatAddress
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    private static func defaultOutputDeviceUID() -> String? {
        guard let deviceID = DefaultAudioDevices.outputDeviceID() else { return nil }

        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
            let uid
        else { return nil }
        return uid.takeRetainedValue() as String
    }
}
