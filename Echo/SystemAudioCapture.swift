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
//  Pipeline: global process tap → private aggregate device → IO proc →
//  resample to 16 kHz mono Float.
//

import AVFoundation
import CoreAudio
import os

final class SystemAudioCapture: AudioCaptureSource {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "SystemAudioCapture")

    var onSamples: (@Sendable ([Float]) -> Void)?
    var onLevel: (@Sendable (CGFloat) -> Void)?

    private var tapID: AudioObjectID?
    private var aggregateID: AudioObjectID?
    private var ioProcID: AudioDeviceIOProcID?
    private var resampler: BufferResampler?
    private var tapFormat: AVAudioFormat?
    private var didLogFirstBuffer = false

    private let ioQueue = DispatchQueue(label: "com.sancrisoft.Echo.systemAudio")

    enum CaptureError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case tapFormatUnavailable
        case aggregateCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)

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
        // A global tap of every process's output, mixed to mono. The empty
        // exclude-list means "tap everything"; Echo plays no audio of its own.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "Echo System Tap"
        description.muteBehavior = .unmuted   // don't silence what the user hears
        description.isPrivate = true
        // NOTE: do NOT touch `isExclusive` — the global-tap initializer sets it to
        // true ("exclude the listed PIDs"); flipping it inverts to "include only
        // the listed PIDs" (none) and the tap delivers pure silence.

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
            Self.log.error("CreateIOProcID failed status=\(procStatus, privacy: .public)")
            throw CaptureError.ioProcFailed(procStatus)
        }
        ioProcID = proc

        let startStatus = AudioDeviceStart(aggregate, proc)
        Self.log.info("AudioDeviceStart status=\(startStatus, privacy: .public)")
        guard startStatus == noErr else { throw CaptureError.ioProcFailed(startStatus) }
    }

    func stop() {
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
