//
//  SystemAudioCapture.swift
//  Echo
//
//  System-audio channel = the teammates in the meeting.
//
//  Uses Core Audio process taps (macOS 14.2+) instead of ScreenCaptureKit, so
//  capturing the device output does NOT start a screen recording: there's no
//  purple screen-sharing indicator and DRM-protected playback (Netflix,
//  Disney+, …) keeps working while we record.
//
//  Pipeline: process tap → private aggregate device → IO proc →
//  resample to 16 kHz mono Float.
//
//  Two tap shapes (SP-008): the default *global* tap hears everything the Mac
//  plays (today's behavior, byte-for-byte), and a *scoped* tap hears only one
//  call app — the include set of its process objects (ADR-026), resolved by
//  the pure `ScopedProcessResolution` and followed live as helpers appear and
//  vanish. Everything after the tap is identical in both shapes.
//

import AppKit
import AVFoundation
import CoreAudio
import os

final class SystemAudioCapture: AudioCaptureSource {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "SystemAudioCapture")
    /// SP-008's empirical instrument: which process objects a scoped tap
    /// actually includes, per app family (spec open questions 1–3). Watch with:
    ///
    ///     log stream --predicate 'subsystem == "com.sancrisoft.Echo"
    ///         && category == "ScopedCapture"' --level info
    static let scopeLog = Logger(subsystem: "com.sancrisoft.Echo", category: "ScopedCapture")

    var onSamples: (@Sendable ([Float]) -> Void)?
    var onLevel: (@Sendable (CGFloat) -> Void)?

    private var tapID: AudioObjectID?
    private var aggregateID: AudioObjectID?
    private var ioProcID: AudioDeviceIOProcID?
    private var resampler: BufferResampler?
    private var tapFormat: AVAudioFormat?
    private var didLogFirstBuffer = false
    /// When this tap's bring-up began, so the first delivered buffer can
    /// report how long the Team channel was actually deaf — the number the
    /// pre-warming decision rests on.
    private var activatedAt: ContinuousClock.Instant?

    // Sample-rate truth (BRN-006). The rate read at start is a claim, not a
    // fact: a Bluetooth headset switching into its call mode drops the output
    // device to 24 kHz while macOS keeps reporting 48 kHz for a while, and a
    // resampler built on that claim halves the audio's duration — the
    // double-speed Team channel. Three defences, cheapest first:
    //
    //   1. `rateGuard` — every buffer is weighed against the wall clock, so a
    //      lying rate is caught from the audio itself (`CaptureRateGuard`).
    //   2. `formatListenerBlock` — macOS's own late correction, taken the
    //      moment it arrives instead of being ignored.
    //   3. A rebuild on output-device change, driven from the session layer:
    //      the aggregate is anchored to one device and cannot follow.
    //
    // All three converge on `adopt(format:reason:)`, and every mutation of
    // the `tapFormat`/`resampler` pair runs on `ioQueue` so nothing races the
    // IO proc reading them.
    private var rateGuard: CaptureRateGuard?
    /// One trace per capture instance: a device that keeps lying should not
    /// write a trace every two seconds.
    private var rateCorrectionTraced = false
    private var didLogRateMeasurement = false

    /// IO-proc accounting. The tap delivers measurably less audio than the
    /// meeting lasts (8% on a real call, with nothing lost downstream — the
    /// writer's counters clear the ingest chain), and only two shapes explain
    /// that: cycles that fire with an empty buffer (the tap idle because
    /// nothing is rendering) or cycles that never fire at all (Core Audio
    /// dropping them because this block ran over its ~11.6 ms budget). The
    /// counters tell them apart. Written on `ioQueue`, read once the IO proc
    /// is stopped; reset per activation, never in `stop()`, so the session
    /// teardown can still read them.
    private var ioProcCycles = 0
    private var emptyCycles = 0
    private var deliveredTapFrames = 0
    /// The *shape* of the loss, which the totals can't show: scattered single
    /// skips mean cycles we failed to be ready for, while a few long gaps mean
    /// the tap itself went quiet and never called. The two need opposite
    /// fixes — schedule better, or declare the silence as a gap.
    /// How many observation windows the rate guard actually reached a verdict
    /// on, and what the last one measured. Zero conclusions on a session that
    /// still came out short would mean the guard is being starved by its own
    /// continuity check — the one remaining way this can fail silently, and
    /// not something to find out by reasoning about it.
    private var rateConclusions = 0
    private var lastMeasuredRate: Double = 0
    private var lastCycleAt: ContinuousClock.Instant?
    private var skippedCycles = 0
    private var secondsLostToSkips: TimeInterval = 0
    private var secondsLostToLongGaps: TimeInterval = 0
    private var longestGapSeconds: TimeInterval = 0

    /// What the tap really delivered this session, for the stop-time
    /// accounting. `nil` when it never came up.
    struct DeliveryStats: Sendable {
        var cycles: Int
        var emptyCycles: Int
        var frames: Int
        var sampleRate: Double
        var uptimeSeconds: TimeInterval
        /// Cycle boundaries where more than one cycle's worth of time passed.
        var skips: Int
        var secondsLostToSkips: TimeInterval
        /// Of that, what sat in gaps of 100 ms or more — the signature of a
        /// tap that stopped calling rather than cycles we arrived late for.
        var secondsLostToLongGaps: TimeInterval
        var longestGapSeconds: TimeInterval
        /// Rate-guard state: windows judged, the last rate measured, and the
        /// rate the tap is currently believed to run at.
        var rateConclusions: Int
        var measuredRate: Double
        var declaredRate: Double

        /// Seconds of audio actually handed over, at the tap's own rate.
        var deliveredSeconds: TimeInterval {
            sampleRate > 0 ? Double(frames) / sampleRate : 0
        }
        /// Seconds the cycles themselves account for — delivered audio plus
        /// what the empty ones would have carried. If this lands near uptime
        /// the tap simply had nothing to give; if it lands short, cycles are
        /// being dropped.
        var cycleCoverageSeconds: TimeInterval {
            let delivering = cycles - emptyCycles
            guard delivering > 0 else { return 0 }
            return deliveredSeconds / Double(delivering) * Double(cycles)
        }
    }

    func deliveryStats() -> DeliveryStats? {
        guard let activatedAt, let tapFormat else { return nil }
        return DeliveryStats(
            cycles: ioProcCycles,
            emptyCycles: emptyCycles,
            frames: deliveredTapFrames,
            sampleRate: tapFormat.sampleRate,
            uptimeSeconds: Self.milliseconds(activatedAt.duration(to: .now)) / 1_000,
            skips: skippedCycles,
            secondsLostToSkips: secondsLostToSkips,
            secondsLostToLongGaps: secondsLostToLongGaps,
            longestGapSeconds: longestGapSeconds,
            rateConclusions: rateConclusions,
            measuredRate: lastMeasuredRate,
            declaredRate: rateGuard?.declaredRate ?? tapFormat.sampleRate
        )
    }
    /// Rates this tap was measured to NOT be running at. Without this the two
    /// defences fight each other: a spurious notification re-reads the same
    /// stale rate the audio already disproved, defence 1 disproves it again
    /// two seconds later, and the flip-flop eats the correction budget until
    /// the lie wins. Measurement outranks the claim — and if the hardware
    /// really does return to a discredited rate, defence 1 measures its way
    /// back to it.
    private var discreditedRates: Set<Double> = []
    private var formatListenerBlock: AudioObjectPropertyListenerBlock?
    private var formatListenerTapID: AudioObjectID?
    private var formatListenerDeviceID: AudioObjectID?

    // Scoped-capture state (SP-008), nil/empty for global sessions. The
    // description object is kept because updating a live tap means writing a
    // *description* back to `kAudioTapPropertyDescription` — mutating this one
    // preserves the UUID the aggregate device references the tap by.
    private var scopedApp: CallApp?
    private var scopedDescription: CATapDescription?
    private var includedObjects: Set<AudioObjectID> = []
    private var followBlock: AudioObjectPropertyListenerBlock?
    /// True while a coalesced follow rescan is already scheduled.
    private var followRescanPending = false
    /// True once the current follow-failure burst has been traced, so a flood
    /// of process-list changes against a wedged tap records one trace, not one
    /// per change. Reset by the next successful update.
    private var followFailureTraced = false

    /// `.userInteractive` on purpose: Core Audio hands this queue an IO cycle
    /// every ~10.7 ms and skips the cycle outright if the block has not been
    /// scheduled by the time the next one is due — the tap loses ~8% of a real
    /// meeting that way (BRN-007), and the work inside the block is measured at
    /// 0.1% of the budget, so the loss is in *reaching* the block, not running
    /// it. An unspecified-QoS queue competes with everything else on the box;
    /// this one is scheduled like the interaction it is.
    private let ioQueue = DispatchQueue(label: "com.sancrisoft.Echo.systemAudio", qos: .userInteractive)

    private static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    enum CaptureError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case tapFormatUnavailable
        case aggregateCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)
        /// Any failure to establish the *scoped* topology at start. Distinct
        /// so the session layer can catch exactly this and fall back to a
        /// global session (ADR-027) — the fallback itself lives there, not here.
        case scopedTapFailed(underlying: any Error)

        var errorDescription: String? {
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

    // MARK: - Lifecycle

    /// Raises macOS's "System Audio Recording" permission prompt ahead of the
    /// first real session. The prompt fires when a process tap actually runs,
    /// so this starts a throwaway capture (no callbacks wired) and tears it
    /// down immediately. Denial is not an error here — the real session start
    /// surfaces its own failure.
    static func primePermission() async {
        let probe = SystemAudioCapture()
        do {
            try await probe.start()
        } catch {
            Self.log.warning("""
            System-audio permission probe failed: \(error.localizedDescription, privacy: .public)
            """)
        }
        probe.stop()
    }

    func start() async throws {
        try await start(scope: .everything)
    }

    /// Starts capture with the given system-channel coverage (SP-008).
    /// `.everything` is today's global tap, unchanged; `.app` taps only that
    /// app's current process objects and follows the set live (ADR-026). Any
    /// scoped-start failure surfaces as `CaptureError.scopedTapFailed` so the
    /// session layer can fall back to a global session (ADR-027).
    func start(scope: CaptureScope) async throws {
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
        description.muteBehavior = .unmuted   // don't silence what the user hears
        description.isPrivate = true
        // NOTE: do NOT touch `isExclusive` — the global-tap initializer sets it to
        // true ("exclude the listed PIDs"); flipping it inverts to "include only
        // the listed PIDs" (none) and the tap delivers pure silence.

        try activate(description)
    }

    /// The scoped topology: resolve the app's process objects, tap exactly
    /// those, then follow the set as helpers appear and vanish. An empty
    /// include set is legal at every point (ADR-026) — verified empirically:
    /// Core Audio accepts an empty-set tap at creation, so there is no lazy
    /// arming; the tap simply delivers nothing until the set grows.
    private func startScoped(to app: CallApp) throws {
        let processes = scopedProcessCandidates()
        let include = ScopedProcessResolution.includeSet(for: app, in: processes.map(\.entry))

        // Mono mixdown of exactly the included process objects. This
        // initializer sets `isExclusive` to false ("include only the listed
        // objects") — the correct sense here; see the global path's warning
        // before considering touching it.
        let description = CATapDescription(monoMixdownOfProcesses: include.sorted())
        description.name = "Echo Scoped System Tap"
        description.muteBehavior = .unmuted   // don't silence what the user hears
        description.isPrivate = true

        try activate(description)

        scopedApp = app
        scopedDescription = description
        includedObjects = include
        try armFollowListener()

        #if DEBUG
        logScope("start", app: app, included: processes.filter { include.contains($0.entry.object) })
        #endif
    }

    /// Tap → aggregate → IO proc → running, shared by both tap shapes.
    ///
    /// Every step is timed. Bringing this path up costs the Team channel its
    /// first seconds of the meeting (the mic is already recording by then, so
    /// the hole is declared as a capture gap by the session layer), and the
    /// only way to know whether pre-warming it would win those seconds back is
    /// to know which step actually spends them — creating the tap, creating
    /// the aggregate, or starting the device. Logged at `notice` so the answer
    /// survives in the system log for reading after the meeting, not only in a
    /// live `log stream`.
    private func activate(_ description: CATapDescription) throws {
        let broughtUpAt = ContinuousClock.now
        var mark = broughtUpAt
        // Reset before the IO proc can possibly fire, not after.
        ioProcCycles = 0
        emptyCycles = 0
        deliveredTapFrames = 0
        lastCycleAt = nil
        rateConclusions = 0
        lastMeasuredRate = 0
        skippedCycles = 0
        secondsLostToSkips = 0
        secondsLostToLongGaps = 0
        longestGapSeconds = 0
        /// Milliseconds since the previous mark.
        func step() -> Double {
            let now = ContinuousClock.now
            defer { mark = now }
            return Self.milliseconds(mark.duration(to: now))
        }

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        let tapMs = step()
        Self.log.info("CreateProcessTap status=\(tapStatus, privacy: .public) tapID=\(tap, privacy: .public)")
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        tapID = tap

        guard let format = readTapFormat(tap) else { throw CaptureError.tapFormatUnavailable }
        tapFormat = format
        resampler = BufferResampler(from: format)
        rateGuard = CaptureRateGuard(declaredRate: format.sampleRate)
        Self.log.info("System tap format: \(format.channelCount, privacy: .public) ch @ \(format.sampleRate, privacy: .public) Hz")

        // Wrap the tap in a private aggregate device so we can run an IO proc.
        let outputUID = defaultOutputDeviceUID()
        Self.log.info("Default output device UID: \(outputUID ?? "nil", privacy: .public)")

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription(tapUID: description.uuid.uuidString, outputUID: outputUID) as CFDictionary,
            &aggregate
        )
        let aggregateMs = step()
        Self.log.info("CreateAggregateDevice status=\(aggregateStatus, privacy: .public) aggID=\(aggregate, privacy: .public)")
        guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
            throw CaptureError.aggregateCreationFailed(aggregateStatus)
        }
        aggregateID = aggregate

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue) { [weak self] _, inInputData, inInputTime, _, _ in
            // The capture timestamp was already being handed to us and thrown
            // away; it is the second clock the rate guard needs.
            self?.handle(inInputData, inputTime: inInputTime)
        }
        let procMs = step()
        guard procStatus == noErr, let proc else {
            ErrorTrace.record(
                "CreateIOProcID failed",
                category: "SystemAudioCapture",
                metadata: ["status": String(procStatus)]
            )
            throw CaptureError.ioProcFailed(procStatus)
        }
        ioProcID = proc

        let startStatus = AudioDeviceStart(aggregate, proc)
        let startMs = step()
        Self.log.info("AudioDeviceStart status=\(startStatus, privacy: .public)")
        guard startStatus == noErr else { throw CaptureError.ioProcFailed(startStatus) }

        armFormatListeners(tap: tap)
        activatedAt = broughtUpAt
        Self.log.notice("""
        System tap brought up in \(Self.milliseconds(broughtUpAt.duration(to: .now)), format: .fixed(precision: 0), privacy: .public) ms \
        (tap \(tapMs, format: .fixed(precision: 0), privacy: .public) / \
        aggregate \(aggregateMs, format: .fixed(precision: 0), privacy: .public) / \
        ioproc \(procMs, format: .fixed(precision: 0), privacy: .public) / \
        start \(startMs, format: .fixed(precision: 0), privacy: .public))
        """)
    }

    func stop() {
        if let followBlock {
            var address = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, followBlock
            )
        }
        followBlock = nil
        disarmFormatListeners()
        scopedApp = nil
        scopedDescription = nil
        includedObjects = []
        followFailureTraced = false
        if let aggregateID, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if let aggregateID { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if let tapID { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = nil
        tapID = nil
        resampler = nil
        tapFormat = nil
        rateGuard = nil
        rateCorrectionTraced = false
        discreditedRates = []
        didLogFirstBuffer = false
        didLogRateMeasurement = false
        activatedAt = nil
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    // MARK: - Scope follow (SP-008 / ADR-026)

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
    /// silently drop a mid-call helper's audio — the failure shape ADR-026
    /// exists to prevent — where the caller's global fallback only ever
    /// over-records, visibly (ADR-027).
    private func armFollowListener() throws {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Registered on the main queue, so this hop is safe.
            MainActor.assumeIsolated { self?.scheduleFollowUpdate() }
        }
        var address = Self.processListAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block
        )
        guard status == noErr else {
            ErrorTrace.record(
                "Scoped-capture process-list listener registration failed",
                category: "ScopedCapture",
                metadata: ["status": String(status)]
            )
            throw FollowListenerRegistrationFailed(status: status)
        }
        followBlock = block
    }

    /// Collapses a burst of process-list notifications into one re-resolution,
    /// the same shape as `MicActivityMonitor.handleChange` and for the same
    /// reason: one real event (an app launching helpers) arrives as several
    /// notifications, and each rescan reads two properties per process.
    private func scheduleFollowUpdate() {
        guard !followRescanPending else { return }
        followRescanPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            self.followRescanPending = false
            self.applyFollowUpdateIfNeeded()
        }
    }

    /// Re-resolves the app's process set and, only when it genuinely changed,
    /// writes the new include set to the LIVE tap through
    /// `kAudioTapPropertyDescription` — verified empirically to accept both
    /// growing and shrinking sets without tearing the tap down. On a failed
    /// write the last successfully applied set stays in force: a running
    /// scoped session never silently widens (ADR-027); the next process-list
    /// change retries against fresh truth.
    private func applyFollowUpdateIfNeeded() {
        guard let scopedApp, let scopedDescription, let tapID,
              followBlock != nil   // a coalesced rescan can land after stop()
        else { return }

        let processes = scopedProcessCandidates()
        guard let newSet = ScopedProcessResolution.followUpdate(
            for: scopedApp, current: includedObjects, processes: processes.map(\.entry)
        ) else { return }

        scopedDescription.processes = newSet.sorted()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var box: CATapDescription? = scopedDescription
        let status = withUnsafeMutablePointer(to: &box) {
            AudioObjectSetPropertyData(
                tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription?>.size), $0
            )
        }
        guard status == noErr else {
            // Keep the description object telling the truth about the tap.
            scopedDescription.processes = includedObjects.sorted()
            if !followFailureTraced {
                followFailureTraced = true
                ErrorTrace.record(
                    "Scoped tap include-set update failed; keeping last-good set",
                    category: "ScopedCapture",
                    metadata: [
                        "status": String(status),
                        "app": scopedApp.displayName,
                        "lastGoodCount": String(includedObjects.count),
                        "rejectedCount": String(newSet.count),
                    ]
                )
            }
            return
        }
        includedObjects = newSet
        followFailureTraced = false

        #if DEBUG
        logScope("follow", app: scopedApp, included: processes.filter { newSet.contains($0.entry.object) })
        #endif
    }

    /// Every process object the audio server knows about, with its bundle
    /// identity — the `MicActivityMonitor` enumeration technique, including
    /// the `NSRunningApplication` fallback for helpers Core Audio reports no
    /// bundle ID for. An object whose pid is unreadable is skipped: it died
    /// between the list read and this call, and the next listener fire brings
    /// the truth. A failed list read yields the empty list, which resolves to
    /// the legal empty set (silence) rather than an error.
    private func scopedProcessCandidates() -> [ScopedProcessCandidate] {
        var address = Self.processListAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects
        ) == noErr else { return [] }

        return objects.compactMap { object in
            guard let pid = pid(of: object) else { return nil }
            return ScopedProcessCandidate(
                pid: pid,
                entry: .init(object: object, bundleID: bundleID(of: object, pid: pid))
            )
        }
    }

    private func pid(of object: AudioObjectID) -> pid_t? {
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
    private func bundleID(of object: AudioObjectID, pid: pid_t) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
           let value {
            let bundleID = value.takeRetainedValue() as String
            if !bundleID.isEmpty { return bundleID }
        }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    }

    #if DEBUG
    /// The scope log itself (SP-008's manual-test instrument): which process
    /// objects the scoped tap includes right now, per app family.
    private func logScope(_ phase: String, app: CallApp, included: [ScopedProcessCandidate]) {
        let rows = included
            .sorted { $0.pid < $1.pid }
            .map { "pid=\($0.pid) bundle=\($0.entry.bundleID.isEmpty ? "<none>" : $0.entry.bundleID)" }
        Self.scopeLog.info("""
        scope \(phase, privacy: .public): app=\(app.displayName, privacy: .public) \
        include(\(included.count, privacy: .public)) — \
        \(rows.isEmpty ? "no matching processes (silence until the app plays)" : rows.joined(separator: " | "), privacy: .public)
        """)
    }
    #endif

    // MARK: - IO

    private func handle(_ bufferList: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>) {
        ioProcCycles += 1
        guard let tapFormat, let resampler else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))

        if !didLogFirstBuffer {
            didLogFirstBuffer = true
            let first = buffers.first
            var peak: Float = 0
            if let raw = first?.mData, let count = first.map({ Int($0.mDataByteSize) / MemoryLayout<Float>.size }), count > 0 {
                let samples = raw.assumingMemoryBound(to: Float.self)
                for i in 0..<count { peak = max(peak, abs(samples[i])) }
            }
            Self.log.info("IO proc fired: \(buffers.count, privacy: .public) buffer(s), ch=\(first?.mNumberChannels ?? 0, privacy: .public), bytes=\(first?.mDataByteSize ?? 0, privacy: .public), peak=\(peak, privacy: .public)")
            if let activatedAt {
                Self.log.notice("""
                First system buffer \(Self.milliseconds(activatedAt.duration(to: .now)), format: .fixed(precision: 0), privacy: .public) ms \
                after bring-up began
                """)
            }
        }

        guard let first = buffers.first, let data = first.mData else {
            emptyCycles += 1
            return
        }

        let bytesPerFrame = max(1, Int(tapFormat.streamDescription.pointee.mBytesPerFrame))
        let frameCount = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        guard frameCount > 0 else {
            emptyCycles += 1
            return
        }
        deliveredTapFrames += Int(frameCount)
        noteCycleInterval(carrying: Int(frameCount), at: tapFormat.sampleRate)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frameCount),
              let destination = pcm.floatChannelData?[0]
        else { return }

        pcm.frameLength = frameCount
        memcpy(destination, data, Int(first.mDataByteSize))

        guard let frames = resampler.resample(pcm) else { return }
        onLevel?(AudioLevelMeter.level(from: frames))
        onSamples?(frames)

        // Last, so a correction takes effect from the next buffer rather than
        // swapping the converter this one is still using.
        verifyDeliveredRate(frames: Int(frameCount), inputTime: inputTime)
    }

    /// Measures the wall time between consecutive cycles against the audio
    /// each one carries. An interval longer than the audio it delivered means
    /// time passed that no cycle covered — and the distribution of those
    /// intervals is what says whether we missed cycles or were never called.
    private func noteCycleInterval(carrying frames: Int, at rate: Double) {
        let now = ContinuousClock.now
        defer { lastCycleAt = now }
        guard let last = lastCycleAt, rate > 0 else { return }

        let cycleSeconds = Double(frames) / rate
        let interval = Self.milliseconds(last.duration(to: now)) / 1_000
        longestGapSeconds = max(longestGapSeconds, interval)
        // Half a cycle of slack: normal jitter is not a skip.
        guard interval > cycleSeconds * 1.5 else { return }
        skippedCycles += 1
        let lost = interval - cycleSeconds
        secondsLostToSkips += lost
        if interval >= 0.1 { secondsLostToLongGaps += lost }
    }

    /// Defence 1: weigh what the tap actually delivered against the wall
    /// clock, and correct the declared rate when they disagree. Two additions
    /// and a comparison per buffer; silent unless a window of continuous
    /// audio contradicts the rate the tap claims (see `CaptureRateGuard`).
    private func verifyDeliveredRate(frames: Int, inputTime: UnsafePointer<AudioTimeStamp>) {
        let stamp = inputTime.pointee
        let deviceSampleTime = stamp.mFlags.contains(.sampleTimeValid) ? stamp.mSampleTime : nil
        guard let verdict = rateGuard?.observe(
            frames: frames, deviceSampleTime: deviceSampleTime, at: .now
        ) else { return }

        if let measured = verdict.measuredRate {
            rateConclusions += 1
            lastMeasuredRate = measured
        }

        // One line per session the first time a window is actually judged.
        // Without it a guard that never judges — a device publishing no valid
        // sample clock, a tap that only delivers in bursts — would be
        // indistinguishable from a guard that judged and found nothing wrong.
        if case .measuring = verdict {} else if !didLogRateMeasurement {
            didLogRateMeasurement = true
            // `notice`, not `info`: this one is read after the fact, and info
            // never reaches the persistent log.
            Self.log.notice("""
            System tap rate check armed: declared \
            \(self.rateGuard?.declaredRate ?? 0, privacy: .public) Hz, \
            delivering \(verdict.measuredRate ?? 0, privacy: .public) Hz
            """)
        }

        guard case .mismatch(let measured) = verdict else { return }
        let corrected = CaptureRateGuard.snapped(measured)
        let declared = rateGuard?.declaredRate ?? 0
        guard rateGuard?.canCorrect == true else {
            traceRateCorrection(declared: declared, measured: measured, adopted: nil)
            return
        }

        Self.log.warning("""
        System tap delivers \(measured, privacy: .public) Hz but declares \
        \(declared, privacy: .public) Hz — adopting \(corrected, privacy: .public) Hz
        """)
        traceRateCorrection(declared: declared, measured: measured, adopted: corrected)
        discreditedRates.insert(declared)
        // Adopt even if rebuilding the converter fails: leaving the guard
        // pointed at a rate we know is wrong would re-fire every window.
        rateGuard?.noteCorrection(to: corrected)
        adoptSampleRate(corrected, reason: "measured delivery")
    }

    private func traceRateCorrection(declared: Double, measured: Double, adopted: Double?) {
        guard !rateCorrectionTraced else { return }
        rateCorrectionTraced = true
        ErrorTrace.record(
            "System tap sample rate disagreed with delivered audio",
            category: "SystemAudioCapture",
            metadata: [
                "declaredHz": String(format: "%.0f", declared),
                "measuredHz": String(format: "%.1f", measured),
                "adoptedHz": adopted.map { String(format: "%.0f", $0) } ?? "none (correction budget spent)",
            ]
        )
    }

    /// Re-labels the incoming audio at `rate`, keeping every other field of
    /// the tap's format. The samples themselves are fine — only the rate they
    /// were filed under was wrong — so this is lossless and gapless: no tap
    /// teardown, no hole in the Team channel.
    private func adoptSampleRate(_ rate: Double, reason: String) {
        guard let current = tapFormat, current.sampleRate != rate else { return }
        var asbd = current.streamDescription.pointee
        asbd.mSampleRate = rate
        guard let corrected = AVAudioFormat(streamDescription: &asbd) else { return }
        adopt(format: corrected, reason: reason)
    }

    /// The single place the format/resampler pair changes after start. Runs
    /// on `ioQueue` — either from the IO proc itself or from a listener that
    /// hopped there — so the IO proc never reads a half-swapped pair.
    private func adopt(format: AVAudioFormat, reason: String) {
        guard let rebuilt = BufferResampler(from: format) else {
            ErrorTrace.record(
                "Couldn't rebuild the system-audio resampler for a corrected format",
                category: "SystemAudioCapture",
                metadata: ["sampleRate": String(format: "%.0f", format.sampleRate), "reason": reason]
            )
            return
        }
        tapFormat = format
        resampler = rebuilt
        Self.log.info("""
        System tap format adopted (\(reason, privacy: .public)): \
        \(format.channelCount, privacy: .public) ch @ \(format.sampleRate, privacy: .public) Hz
        """)
    }

    // MARK: - Format changes (defence 2)

    /// Listens for the format correction macOS itself publishes — the one the
    /// AirPods defect eventually sends and that reading the format once can
    /// never see. Registered on the tap (its own format property) and on the
    /// output device that clocks it (stream format and nominal rate), because
    /// which of the three fires is device-dependent; they all lead to the same
    /// idempotent re-read.
    private func armFormatListeners(tap: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Registered on the main queue; the reaction belongs on the IO
            // queue, where every format mutation is serialized.
            self.ioQueue.async { self.refreshTapFormat(reason: "macOS format-change notification") }
        }
        formatListenerBlock = block

        var tapAddress = Self.tapFormatAddress
        if AudioObjectAddPropertyListenerBlock(tap, &tapAddress, .main, block) == noErr {
            formatListenerTapID = tap
        }

        guard let deviceID = defaultOutputDeviceID() else { return }
        var attached = false
        for address in Self.deviceFormatAddresses {
            var address = address
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block) == noErr {
                attached = true
            }
        }
        if attached { formatListenerDeviceID = deviceID }
    }

    private func disarmFormatListeners() {
        guard let block = formatListenerBlock else { return }
        if let tap = formatListenerTapID {
            var address = Self.tapFormatAddress
            AudioObjectRemovePropertyListenerBlock(tap, &address, .main, block)
        }
        if let deviceID = formatListenerDeviceID {
            for address in Self.deviceFormatAddresses {
                var address = address
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
            }
        }
        formatListenerBlock = nil
        formatListenerTapID = nil
        formatListenerDeviceID = nil
    }

    /// Re-reads the tap's format and adopts it when it genuinely changed.
    /// Idempotent by design: the three listeners routinely fire together for
    /// one real event, and a `stop()` racing a queued notification lands on
    /// the `tapID` guard (a destroyed object simply fails the read).
    private func refreshTapFormat(reason: String) {
        guard let tapID, let current = tapFormat, let fresh = readTapFormat(tapID) else { return }
        guard fresh.sampleRate != current.sampleRate
                || fresh.channelCount != current.channelCount
        else { return }
        guard !discreditedRates.contains(fresh.sampleRate) else {
            Self.log.info("""
            Ignoring a re-declared \(fresh.sampleRate, privacy: .public) Hz — the delivered \
            audio already disproved it
            """)
            return
        }

        adopt(format: fresh, reason: reason)
        // The guard now measures against the freshly declared rate; if this
        // one is a lie too, defence 1 catches it two seconds later.
        rateGuard = CaptureRateGuard(declaredRate: fresh.sampleRate)
    }

    // MARK: - Core Audio helpers

    private func aggregateDescription(tapUID: String, outputUID: String?) -> [String: Any] {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Echo System Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
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

    private func readTapFormat(_ tap: AudioObjectID) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = Self.tapFormatAddress
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    /// The device where app audio actually plays (e.g. the external monitor),
    /// NOT DefaultSystemOutputDevice (the alerts device).
    private func defaultOutputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown
        else { return nil }
        return deviceID
    }

    private func defaultOutputDeviceUID() -> String? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }

        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
