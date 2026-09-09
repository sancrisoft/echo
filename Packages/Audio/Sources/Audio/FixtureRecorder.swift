//
//  FixtureRecorder.swift
//  Audio
//
//  DEBUG-only harness for recording the fixture suites on real hardware:
//  both capture channels run simultaneously for a fixed take and the raw
//  16 kHz mono streams are written as paired WAVs. There is deliberately NO
//  AEC stage anywhere in this path — `mic.wav` is the raw near-end signal
//  including speaker bleed, `system.wav` the far-end reference. Fixtures must
//  be real recordings (never synthesized), and this utility is the one
//  sanctioned way to produce them (see Fixtures/README.md).
//
//  When the input device is multi-channel the take additionally preserves the
//  mic's native pre-downmix stream as `mic-native.wav`, so the downmix stays
//  offline-testable against real device audio; and `info.json` records the
//  input device's facts plus the macOS input-volume position — the "was the
//  slider sane" check becomes recorded metadata.
//
//  An `actor`: it owns the take's phase and sequences two capture sources,
//  and v1's `@Observable @MainActor` was a consequence of the DEBUG picker
//  view that drove it. An observable façade belongs to whichever package
//  renders it and must not become a second copy of the state (ADR-003), so
//  phase changes leave through a callback instead.
//

#if DEBUG

    import AVFoundation
    import CoreAudio
    import EchoCore
    import Foundation
    import Synchronization

    /// The fixture scenarios — the echo-cancellation set and the
    /// external-input-device set (see Fixtures/README.md for the recording
    /// instructions each of these implies). Raw values are the fixture folder
    /// names under `Fixtures/`.
    public enum FixtureScenario: String, CaseIterable, Sendable {
        // Echo cancellation (built-in mic + built-in loudspeakers).
        case bleedOnly = "bleed-only"
        case doubleTalk = "double-talk"
        case doubleTalkBaseline = "double-talk-baseline"
        case monologue = "monologue"
        case routeChange = "route-change"

        // External input devices. The four parity takes share one script so
        // parity is judged baseline-relative, utterance by utterance.
        case parityBaselineBuiltin = "parity-baseline-builtin"
        case parityDJI20cm = "parity-dji-20cm"
        case parityDJI50cm = "parity-dji-50cm"
        case parityDJI2cm = "parity-dji-2cm"
        case earbudsInOut = "earbuds-in-out"
        case externalAmbient = "external-ambient"

        public var id: String { rawValue }
    }

    /// Accumulates canonical samples off the capture callbacks. A 30 s take is
    /// ~2 MB per channel, so buffering the whole take in memory is fine.
    ///
    /// Behind a `Mutex` because `append` runs on the AVAudioEngine render thread
    /// (microphone) and on the Core Audio IO queue (system), while `drain` runs
    /// on the recorder's actor once both are stopped.
    private final class SampleSink: Sendable {

        private let samples = Mutex<[Float]>([])

        func append(_ frames: [Float]) {
            samples.withLock { $0.append(contentsOf: frames) }
        }

        func drain() -> [Float] {
            samples.withLock { $0 }
        }
    }

    /// Accumulates the mic tap's native-format buffers — pre-downmix,
    /// pre-resample — so multi-channel takes can be preserved as
    /// `mic-native.wav`. Same threading contract as `SampleSink`: `append` runs
    /// on the audio render thread and must copy synchronously, because the engine
    /// reuses tap buffers after the callback returns.
    ///
    /// Keyed to the first buffer's format; a mid-take device switch would
    /// invalidate the take anyway, so later buffers in a different format are
    /// dropped rather than mixed into one file.
    private final class NativeBufferSink: Sendable {

        private struct Native {
            var channels: [[Float]] = []
            var sampleRate: Double = 0
        }

        private let state = Mutex(Native())

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
            let sampleRate = buffer.format.sampleRate

            state.withLock { state in
                if state.channels.isEmpty {
                    state.channels = Array(repeating: [], count: channelCount)
                    state.sampleRate = sampleRate
                }
                guard channelCount == state.channels.count, sampleRate == state.sampleRate else { return }
                for channel in 0..<channelCount {
                    state.channels[channel].append(
                        contentsOf: UnsafeBufferPointer(start: source[channel], count: frames)
                    )
                }
            }
        }

        func drain() -> (channels: [[Float]], sampleRate: Double) {
            state.withLock { ($0.channels, $0.sampleRate) }
        }
    }

    public actor FixtureRecorder {

        public enum Phase: Equatable, Sendable {
            case idle
            case countingDown(Int)
            case recording(secondsRemaining: Int)
            case finished(URL)
            case failed(String)
        }

        /// Take length in seconds. Fixed: the scripted double-talk timing in the
        /// fixtures README (and the spans the AEC signal-level suite hardcodes)
        /// assume it.
        public static let takeDuration = 30
        public static let countdownSeconds = 3

        public private(set) var phase: Phase = .idle

        public var isBusy: Bool {
            switch phase {
            case .countingDown, .recording: return true
            case .idle, .finished, .failed: return false
            }
        }

        public enum RecorderError: LocalizedError {
            case emptyCapture(channel: String)
            case bufferAllocationFailed

            public var errorDescription: String? {
                switch self {
                case .emptyCapture(let channel):
                    return "No \(channel) audio was captured — nothing was written."
                case .bufferAllocationFailed:
                    return "Couldn't allocate the audio buffer for writing."
                }
            }
        }

        /// Reports every phase change, for a harness that renders progress.
        private let onPhase: (@Sendable (Phase) -> Void)?

        /// How the output route is named in `info.json` — which hardware the
        /// take was recorded on. Injected rather than read inline so a caller
        /// replaying a take can name the route it belongs to, and so this
        /// stayed buildable in the capture layer, before route
        /// classification existed.
        private let routeDescription: @Sendable () -> String

        public init(
            onPhase: (@Sendable (Phase) -> Void)? = nil,
            routeDescription: @escaping @Sendable () -> String = {
                String(describing: OutputRouteMonitor().currentRoute())
            }
        ) {
            self.onPhase = onPhase
            self.routeDescription = routeDescription
        }

        private func transition(to phase: Phase) {
            self.phase = phase
            onPhase?(phase)
        }

        /// Records one take and writes `{directory}/{scenario}/mic.wav`,
        /// `system.wav`, `info.json`, and — when the input device is
        /// multi-channel — `mic-native.wav`. Never run this while a normal
        /// recording session is active: both would fight over the capture
        /// hardware.
        public func record(scenario: FixtureScenario, into directory: URL) async {
            guard !isBusy else { return }

            // Captured up front: the route and the input-device facts name what
            // hardware the take was recorded on (headphones baseline vs
            // loudspeakers; built-in mic vs USB receiver vs earbuds).
            let route = routeDescription()
            let inputDevice = InputDeviceFactsReader.read()

            let micSink = SampleSink()
            let systemSink = SampleSink()
            let nativeSink = NativeBufferSink()

            let mic = MicrophoneCapture(
                onSamples: { micSink.append($0) },
                onRawBuffer: { nativeSink.append($0) }
            )
            let system = SystemAudioCapture(onSamples: { systemSink.append($0) })

            for second in stride(from: Self.countdownSeconds, to: 0, by: -1) {
                transition(to: .countingDown(second))
                try? await Task.sleep(for: .seconds(1))
            }

            do {
                try await mic.start()
                try system.start()
            } catch {
                mic.stop()
                system.stop()
                transition(to: .failed(error.localizedDescription))
                return
            }

            for second in stride(from: Self.takeDuration, to: 0, by: -1) {
                transition(to: .recording(secondsRemaining: second))
                try? await Task.sleep(for: .seconds(1))
            }

            mic.stop()
            system.stop()

            do {
                let folder = try Self.write(
                    micSamples: micSink.drain(),
                    systemSamples: systemSink.drain(),
                    nativeCapture: nativeSink.drain(),
                    scenario: scenario,
                    route: route,
                    inputDevice: inputDevice,
                    into: directory
                )
                transition(to: .finished(folder))
            } catch {
                transition(to: .failed(error.localizedDescription))
            }
        }

        // MARK: - Output

        /// The `info.json` payload. Write-only in practice (the tests read only
        /// the WAVs; this is metadata for humans), but kept decodable and
        /// additive: the input-device field is optional so every earlier
        /// `info.json` remains valid.
        public struct FixtureInfo: Codable, Sendable {
            public let scenario: String
            public let recordedAt: Date
            public let durationSeconds: Double
            public let sampleRate: Double
            public let outputRouteAtRecordTime: String
            /// Which input device the take was captured on, plus the macOS
            /// input-volume position. `nil` when Core Audio exposed no default
            /// input device (and in every file written before it was recorded).
            public let inputDevice: InputDeviceFacts?

            public init(
                scenario: String,
                recordedAt: Date,
                durationSeconds: Double,
                sampleRate: Double,
                outputRouteAtRecordTime: String,
                inputDevice: InputDeviceFacts?
            ) {
                self.scenario = scenario
                self.recordedAt = recordedAt
                self.durationSeconds = durationSeconds
                self.sampleRate = sampleRate
                self.outputRouteAtRecordTime = outputRouteAtRecordTime
                self.inputDevice = inputDevice
            }
        }

        private static func write(
            micSamples: [Float],
            systemSamples: [Float],
            nativeCapture: (channels: [[Float]], sampleRate: Double),
            scenario: FixtureScenario,
            route: String,
            inputDevice: InputDeviceFacts?,
            into directory: URL
        ) throws -> URL {
            guard !micSamples.isEmpty else { throw RecorderError.emptyCapture(channel: "microphone") }
            guard !systemSamples.isEmpty else { throw RecorderError.emptyCapture(channel: "system") }

            let folder = directory.appending(path: scenario.rawValue, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            try writeWAV(micSamples, to: folder.appending(path: "mic.wav", directoryHint: .notDirectory))
            try writeWAV(systemSamples, to: folder.appending(path: "system.wav", directoryHint: .notDirectory))

            // Native-form preservation: multi-channel devices additionally keep
            // the pre-downmix tap stream. Mono devices write nothing — their
            // mic.wav already carries the whole device signal. The stale-file
            // removal keeps re-records honest: a mono re-take of a scenario must
            // not leave an old multi-channel file behind.
            let nativeURL = folder.appending(path: "mic-native.wav", directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: nativeURL)
            if nativeCapture.channels.count > 1 {
                try writeWAV(
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
                outputRouteAtRecordTime: route,
                inputDevice: inputDevice
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(info).write(to: folder.appending(path: "info.json", directoryHint: .notDirectory))

            return folder
        }

        /// Writes 16 kHz mono Float32 samples as a WAV — the fixture loaders'
        /// counterpart, round-tripped against them in the tests.
        public static func writeWAV(_ samples: [Float], to url: URL) throws {
            try? FileManager.default.removeItem(at: url)

            guard let format = AudioConstants.captureFormat else { throw RecorderError.bufferAllocationFailed }
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(samples.count)
                ),
                let destination = buffer.floatChannelData?[0]
            else { throw RecorderError.bufferAllocationFailed }

            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                destination.update(from: base, count: samples.count)
            }
            try file.write(from: buffer)
        }

        /// Writes non-interleaved Float32 channel arrays as a WAV at an arbitrary
        /// sample rate — the native-form writer behind `mic-native.wav`: channel
        /// count and device rate are preserved exactly, so the downmix's realism
        /// check replays the true device signal. Kept separate from the mono
        /// writer above so that one's output byte layout stays untouched.
        public static func writeWAV(channels: [[Float]], sampleRate: Double, to url: URL) throws {
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
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(frameCount)
                ),
                let destination = buffer.floatChannelData
            else { throw RecorderError.bufferAllocationFailed }

            buffer.frameLength = AVAudioFrameCount(frameCount)
            for (channel, samples) in channels.enumerated() {
                samples.withUnsafeBufferPointer { source in
                    guard let base = source.baseAddress else { return }
                    destination[channel].update(from: base, count: frameCount)
                }
            }
            try file.write(from: buffer)
        }
    }

    // MARK: - Input-device facts

    /// The input-device block of `info.json`: name, transport, channel count,
    /// native sample rate, and the macOS input-volume position. Every field is
    /// optional — Core Audio properties a device does not publish are recorded as
    /// absent, never guessed.
    public struct InputDeviceFacts: Codable, Equatable, Sendable {
        public let name: String?
        public let transportType: String?
        public let channelCount: Int?
        /// The device's nominal rate (e.g. 48000 for a USB receiver) — named
        /// apart from the take's canonical 16 kHz `sampleRate` one level up.
        public let nativeSampleRate: Double?
        /// The macOS input-volume slider (0–1), as recorded metadata. `nil` when
        /// the device exposes no input-volume control (some USB interfaces
        /// don't).
        public let inputVolume: Double?

        public init(
            name: String?,
            transportType: String?,
            channelCount: Int?,
            nativeSampleRate: Double?,
            inputVolume: Double?
        ) {
            self.name = name
            self.transportType = transportType
            self.channelCount = channelCount
            self.nativeSampleRate = nativeSampleRate
            self.inputVolume = inputVolume
        }
    }

    /// Reads the default input device's facts via Core Audio. Facts are metadata
    /// for `info.json`: every read degrades to nil rather than failing a take.
    public enum InputDeviceFactsReader {

        public static func read() -> InputDeviceFacts? {
            guard let deviceID = DefaultAudioDevices.inputDeviceID() else { return nil }
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
        /// `info.json` instead of collapsing to "unknown".
        public static func transportName(_ transport: UInt32) -> String {
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
                guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }),
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
        /// engine's tap format reflects (e.g. 2 for a two-transmitter receiver).
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
