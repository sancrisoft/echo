//
//  FixtureRecorder.swift
//  Echo
//
//  DEBUG-only harness for recording the SP-001 and SP-002 fixture suites on
//  real hardware: both capture channels run simultaneously for a fixed take
//  and the raw 16 kHz mono streams are written as paired WAVs. There is
//  deliberately NO AEC stage anywhere in this path — mic.wav is the raw
//  near-end signal including speaker bleed, system.wav the far-end
//  reference. Fixtures must be real recordings (project rule: no simulated
//  audio data); this utility is the one sanctioned way to produce them.
//
//  SP-002 extensions (Testing Decisions, "fixture suite extension"): when
//  the input device is multi-channel, the take additionally preserves the
//  mic's native pre-downmix stream as mic-native.wav so ADR-004's downmix
//  stays offline-testable against real device audio; and info.json records
//  the input device's facts plus the macOS input-volume position — BRN-002's
//  "was the slider sane" check becomes recorded metadata.
//

#if DEBUG

import AVFoundation
import CoreAudio
import Foundation
import Observation

/// The fixture scenarios — SP-001's echo-cancellation set and SP-002's
/// external-input-device set (see EchoTests/Fixtures/README.md for the
/// recording instructions each of these implies). Raw values are the fixture
/// folder names under EchoTests/Fixtures.
enum FixtureScenario: String, CaseIterable, Identifiable {
    // SP-001 — echo cancellation (built-in mic + built-in loudspeakers).
    case bleedOnly = "bleed-only"
    case doubleTalk = "double-talk"
    case doubleTalkBaseline = "double-talk-baseline"
    case monologue = "monologue"
    case routeChange = "route-change"

    // SP-002 — external input devices. The four parity takes share one
    // script so parity is judged baseline-relative, utterance by utterance
    // (SP-002 Success Criteria, USB-class parity).
    case parityBaselineBuiltin = "parity-baseline-builtin"
    case parityDJI20cm = "parity-dji-20cm"
    case parityDJI50cm = "parity-dji-50cm"
    case parityDJI2cm = "parity-dji-2cm"
    case earbudsInOut = "earbuds-in-out"
    case externalAmbient = "external-ambient"

    var id: String { rawValue }
}

/// Thread-safe sample accumulator: capture callbacks arrive on real-time
/// audio threads. A 30 s take is ~2 MB per channel, so buffering the whole
/// take in memory is fine.
private final class SampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ frames: [Float]) {
        lock.lock()
        samples.append(contentsOf: frames)
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

/// Accumulates the mic tap's native-format buffers — pre-downmix,
/// pre-resample — so multi-channel takes can be preserved as mic-native.wav
/// (SP-002 / ADR-004 follow-up: the downmix must stay offline-testable
/// against the true device signal). Same threading contract as `SampleSink`:
/// `append` runs on the audio render thread and must copy synchronously (the
/// engine reuses tap buffers after the callback returns).
///
/// Keyed to the first buffer's format; a mid-take device switch would
/// invalidate the take anyway, so later buffers in a different format are
/// dropped rather than mixed into one file.
private final class NativeBufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [[Float]] = []
    private var sampleRate: Double = 0

    func append(_ buffer: AVAudioPCMBuffer) {
        // Non-interleaved Float32 is the AVAudioEngine tap layout; anything
        // else can't be indexed per channel below, so skip it defensively.
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              let source = buffer.floatChannelData
        else { return }

        let channelCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channelCount > 0, frames > 0 else { return }

        lock.lock()
        defer { lock.unlock() }
        if channels.isEmpty {
            channels = Array(repeating: [], count: channelCount)
            sampleRate = buffer.format.sampleRate
        }
        guard channelCount == channels.count, buffer.format.sampleRate == sampleRate else { return }
        for channel in 0 ..< channelCount {
            channels[channel].append(contentsOf: UnsafeBufferPointer(start: source[channel], count: frames))
        }
    }

    func drain() -> (channels: [[Float]], sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (channels: channels, sampleRate: sampleRate)
    }
}

@Observable
@MainActor
final class FixtureRecorder {

    enum Phase: Equatable {
        case idle
        case countingDown(Int)
        case recording(secondsRemaining: Int)
        case finished(URL)
        case failed(String)
    }

    /// Take length in seconds. Fixed: the scripted double-talk timing in the
    /// README (and the spans hardcoded in AECSignalLevelTests) assume it.
    static let takeDuration = 30
    static let countdownSeconds = 3

    private(set) var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .countingDown, .recording: return true
        case .idle, .finished, .failed: return false
        }
    }

    enum RecorderError: LocalizedError {
        case emptyCapture(channel: String)
        case bufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .emptyCapture(let channel):
                return "No \(channel) audio was captured — nothing was written."
            case .bufferAllocationFailed:
                return "Couldn't allocate the audio buffer for writing."
            }
        }
    }

    /// Records one take and writes `{directory}/{scenario}/mic.wav`,
    /// `system.wav`, `info.json`, and — when the input device is
    /// multi-channel — `mic-native.wav`. Never run this while a normal
    /// recording session is active — both would fight over the capture
    /// hardware.
    func record(scenario: FixtureScenario, into directory: URL) async {
        guard !isBusy else { return }

        // Captured up front: the route and the input-device facts name what
        // hardware the take was recorded on (headphones baseline vs
        // loudspeakers; built-in mic vs DJI receiver vs earbuds — SP-002).
        let route = OutputRouteMonitor().currentRoute()
        let inputDevice = InputDeviceFactsReader.read()

        let mic = MicrophoneCapture()
        let system = SystemAudioCapture()
        let micSink = SampleSink()
        let systemSink = SampleSink()
        let nativeSink = NativeBufferSink()
        mic.onSamples = { micSink.append($0) }
        mic.onRawBuffer = { nativeSink.append($0) }
        system.onSamples = { systemSink.append($0) }

        for second in stride(from: Self.countdownSeconds, to: 0, by: -1) {
            phase = .countingDown(second)
            try? await Task.sleep(for: .seconds(1))
        }

        do {
            try await mic.start()
            try await system.start()
        } catch {
            mic.stop()
            system.stop()
            phase = .failed(error.localizedDescription)
            return
        }

        for second in stride(from: Self.takeDuration, to: 0, by: -1) {
            phase = .recording(secondsRemaining: second)
            try? await Task.sleep(for: .seconds(1))
        }

        mic.stop()
        system.stop()

        do {
            let folder = try write(
                micSamples: micSink.drain(),
                systemSamples: systemSink.drain(),
                nativeCapture: nativeSink.drain(),
                scenario: scenario,
                route: route,
                inputDevice: inputDevice,
                into: directory
            )
            phase = .finished(folder)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Output

    /// The info.json payload. Write-only in production (the tests read only
    /// the WAVs; this is metadata for humans), but kept decodable and
    /// additive: the SP-002 field is optional so every pre-SP-002 info.json
    /// remains valid. Internal so the test target can pin the JSON keys.
    nonisolated struct FixtureInfo: Codable {
        let scenario: String
        let recordedAt: Date
        let durationSeconds: Double
        let sampleRate: Double
        let outputRouteAtRecordTime: String
        /// SP-002: which input device the take was captured on, plus the
        /// macOS input-volume position. `nil` when Core Audio exposed no
        /// default input device (and in every pre-SP-002 file).
        let inputDevice: InputDeviceFacts?
    }

    private func write(
        micSamples: [Float],
        systemSamples: [Float],
        nativeCapture: (channels: [[Float]], sampleRate: Double),
        scenario: FixtureScenario,
        route: OutputRouteClass,
        inputDevice: InputDeviceFacts?,
        into directory: URL
    ) throws -> URL {
        guard !micSamples.isEmpty else { throw RecorderError.emptyCapture(channel: "microphone") }
        guard !systemSamples.isEmpty else { throw RecorderError.emptyCapture(channel: "system") }

        let folder = directory.appendingPathComponent(scenario.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try Self.writeWAV(micSamples, to: folder.appendingPathComponent("mic.wav"))
        try Self.writeWAV(systemSamples, to: folder.appendingPathComponent("system.wav"))

        // Native-form preservation (SP-002 / ADR-004): multi-channel devices
        // additionally keep the pre-downmix tap stream. Mono devices write
        // nothing — their mic.wav already carries the whole device signal.
        // The stale-file removal keeps re-records honest: a mono re-take of
        // a scenario must not leave an old multi-channel file behind.
        let nativeURL = folder.appendingPathComponent("mic-native.wav")
        try? FileManager.default.removeItem(at: nativeURL)
        if nativeCapture.channels.count > 1 {
            try Self.writeWAV(
                channels: nativeCapture.channels,
                sampleRate: nativeCapture.sampleRate,
                to: nativeURL
            )
        }

        let info = FixtureInfo(
            scenario: scenario.rawValue,
            recordedAt: Date(),
            durationSeconds: Double(micSamples.count) / AudioConstants.sampleRate,
            sampleRate: AudioConstants.sampleRate,
            outputRouteAtRecordTime: String(describing: route),
            inputDevice: inputDevice
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: folder.appendingPathComponent("info.json"))

        return folder
    }

    /// Writes 16 kHz mono Float32 samples as a WAV. Internal (not private)
    /// so the test target can round-trip the real writer against the real
    /// fixture loader.
    nonisolated static func writeWAV(_ samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)

        let format = AudioConstants.whisperFormat
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { throw RecorderError.bufferAllocationFailed }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    /// Writes non-interleaved Float32 channel arrays as a WAV at an
    /// arbitrary sample rate — the native-form writer behind mic-native.wav
    /// (SP-002: channel count and device rate are preserved exactly, so
    /// ADR-004's realism check replays the true device signal). Kept
    /// separate from the mono writer above so the SP-001 output byte layout
    /// stays untouched. Internal so the test target can round-trip it
    /// against `Fixtures.loadNativeWAV`.
    nonisolated static func writeWAV(channels: [[Float]], sampleRate: Double, to url: URL) throws {
        guard
            let frameCount = channels.first?.count, frameCount > 0,
            channels.allSatisfy({ $0.count == frameCount }),
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels.count),
                interleaved: false
            )
        else { throw RecorderError.bufferAllocationFailed }

        try? FileManager.default.removeItem(at: url)

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { throw RecorderError.bufferAllocationFailed }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        for (channel, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![channel].update(from: source.baseAddress!, count: frameCount)
            }
        }
        try file.write(from: buffer)
    }
}

// MARK: - Input-device facts (SP-002)

/// The input-device block of info.json (SP-002 Testing Decisions): name,
/// transport, channel count, native sample rate, and the macOS input-volume
/// position. Every field is optional — Core Audio properties a device does
/// not publish are recorded as absent, never guessed.
nonisolated struct InputDeviceFacts: Codable, Equatable {
    let name: String?
    let transportType: String?
    let channelCount: Int?
    /// The device's nominal rate (e.g. 48000 for the DJI receiver) — named
    /// apart from the take's canonical 16 kHz `sampleRate` one level up.
    let nativeSampleRate: Double?
    /// The macOS input-volume slider (0–1) — BRN-002's "was the slider sane
    /// during the test?" check as recorded metadata. `nil` when the device
    /// exposes no input-volume control (some USB interfaces don't).
    let inputVolume: Double?
}

/// Reads the default input device's facts via Core Audio, mirroring
/// `OutputRouteMonitor`'s property-reading style. Facts are metadata for
/// info.json: every read degrades to nil rather than failing a take.
enum InputDeviceFactsReader {

    static func read() -> InputDeviceFacts? {
        guard let deviceID = InputDeviceMonitor().currentDefaultInputDevice() else { return nil }
        return InputDeviceFacts(
            name: readString(deviceID, Self.nameAddress),
            transportType: readUInt32(deviceID, Self.transportTypeAddress).map(transportName),
            channelCount: inputChannelCount(deviceID),
            nativeSampleRate: readFloat64(deviceID, Self.nominalSampleRateAddress),
            inputVolume: inputVolume(deviceID)
        )
    }

    /// Human-readable transport names for the common cases, with a
    /// four-char-code fallback so an exotic transport stays identifiable in
    /// info.json instead of collapsing to "unknown".
    nonisolated static func transportName(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeUnknown: return "unknown"
        case kAudioDeviceTransportTypeBuiltIn: return "builtIn"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetoothLE"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAirPlay: return "airPlay"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeFireWire: return "fireWire"
        case kAudioDeviceTransportTypePCI: return "pci"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayPort"
        case kAudioDeviceTransportTypeAVB: return "avb"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "continuityCaptureWired"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuityCaptureWireless"
        default:
            let bytes = [24, 16, 8, 0].map { UInt8((transport >> $0) & 0xFF) }
            guard bytes.allSatisfy({ (0x20 ... 0x7E).contains($0) }),
                  let fourCC = String(bytes: bytes, encoding: .ascii)
            else { return String(transport) }
            return fourCC
        }
    }

    // MARK: - Core Audio reads

    private static let nameAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let transportTypeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let nominalSampleRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Total input channels across the device's input streams — what the
    /// engine's tap format reflects (e.g. 2 for the DJI receiver's TX1/TX2).
    private static func inputChannelCount(_ deviceID: AudioObjectID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0
        else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return nil }

        let bufferList = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        let channels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
        return channels > 0 ? channels : nil
    }

    /// The macOS input-volume position. Master element first, then channel 1
    /// (many devices publish per-channel volume only); nil when the device
    /// exposes no input-volume control at all.
    private static func inputVolume(_ deviceID: AudioObjectID) -> Double? {
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { continue }
            return Double(value)
        }
        return nil
    }

    private static func readString(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = address
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
              let name = value?.takeRetainedValue()
        else { return nil }
        return name as String
    }

    private static func readUInt32(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func readFloat64(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Double? {
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = address
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

#endif
