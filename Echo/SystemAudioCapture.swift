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

    private let ioQueue = DispatchQueue(label: "com.sancrisoft.Echo.systemAudio")

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
    private func activate(_ description: CATapDescription) throws {
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        Self.log.info("CreateProcessTap status=\(tapStatus, privacy: .public) tapID=\(tap, privacy: .public)")
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        tapID = tap

        guard let format = readTapFormat(tap) else { throw CaptureError.tapFormatUnavailable }
        tapFormat = format
        resampler = BufferResampler(from: format)
        Self.log.info("System tap format: \(format.channelCount, privacy: .public) ch @ \(format.sampleRate, privacy: .public) Hz")

        // Wrap the tap in a private aggregate device so we can run an IO proc.
        let outputUID = defaultOutputDeviceUID()
        Self.log.info("Default output device UID: \(outputUID ?? "nil", privacy: .public)")

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription(tapUID: description.uuid.uuidString, outputUID: outputUID) as CFDictionary,
            &aggregate
        )
        Self.log.info("CreateAggregateDevice status=\(aggregateStatus, privacy: .public) aggID=\(aggregate, privacy: .public)")
        guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
            throw CaptureError.aggregateCreationFailed(aggregateStatus)
        }
        aggregateID = aggregate

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue) { [weak self] _, inInputData, _, _, _ in
            self?.handle(inInputData)
        }
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
        Self.log.info("AudioDeviceStart status=\(startStatus, privacy: .public)")
        guard startStatus == noErr else { throw CaptureError.ioProcFailed(startStatus) }
    }

    func stop() {
        if let followBlock {
            var address = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, followBlock
            )
        }
        followBlock = nil
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
        didLogFirstBuffer = false
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

    private func handle(_ bufferList: UnsafePointer<AudioBufferList>) {
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
        }

        guard let first = buffers.first, let data = first.mData else { return }

        let bytesPerFrame = max(1, Int(tapFormat.streamDescription.pointee.mBytesPerFrame))
        let frameCount = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frameCount),
              let destination = pcm.floatChannelData?[0]
        else { return }

        pcm.frameLength = frameCount
        memcpy(destination, data, Int(first.mDataByteSize))

        guard let frames = resampler.resample(pcm) else { return }
        onLevel?(AudioLevelMeter.level(from: frames))
        onSamples?(frames)
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

    private func readTapFormat(_ tap: AudioObjectID) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    private func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var deviceAddress = AudioObjectPropertyAddress(
            // The device where app audio actually plays (e.g. the external
            // monitor), NOT DefaultSystemOutputDevice (the alerts device).
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown
        else { return nil }

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
