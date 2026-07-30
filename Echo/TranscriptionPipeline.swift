//
//  TranscriptionPipeline.swift
//  Echo
//
//  Turns the two 16 kHz mono Float streams into transcript segments:
//    - microphone → WhisperKit → labeled as the user (`.me`)
//    - system     → WhisperKit → labeled as the teammates (`.teammates`)
//
//  Audio is buffered per channel and cut at natural pauses (energy-based VAD
//  endpointing) so chunks land *between* words instead of slicing through one.
//  Per-speaker diarization was dropped for the PoC; the system stream is one
//  generic "Team" speaker.
//

import Foundation
import WhisperKit
import os

/// Derived per-chunk audio metrics that the speech gates evaluate. A pure
/// value of numbers — it never carries samples, which is what lets the gate
/// diagnostics record (SP-002 NFR Privacy) embed it wholesale.
nonisolated struct AudioStats: Sendable {

    let rms: Float
    let peak: Float
    let activeRatio: Float
    let speechWindowRatio: Float
    let strongWindowRatio: Float
    let noiseFloorRMS: Float
    let dynamicRangeDB: Float
    let crestFactor: Float

    /// Conservative evidence that the chunk contains actual speech instead
    /// of low-level residue/silence that Whisper may hallucinate over.
    /// The individual thresholds live on `GateTerm` so the SP-002 gate
    /// diagnostics report exactly the terms this decision runs on.
    var hasClearSpeech: Bool {
        GateTerm.clearSpeech.allSatisfy { $0.passes(self) }
    }

    var hasTranscribableSpeech: Bool {
        hasClearSpeech || GateTerm.loudFallback.allSatisfy { $0.passes(self) }
    }

    var isMarginalSpeech: Bool {
        !hasClearSpeech || rms < 0.014 || speechWindowRatio < 0.16
    }

    // MARK: - Computation

    /// Analysis window for the energy probe (~30 ms). Shared with the
    /// pipeline's VAD endpointing so gating and pause detection agree on
    /// what a window is.
    static let probeSamples = Int(AudioConstants.sampleRate * 0.03)

    /// A window quieter than this (RMS) is treated as non-speech. Above the
    /// `isSilent` floor so room tone / breaths still register as a pause.
    static let pauseRMS: Float = 0.01

    /// The production gate-metric computation, exposed as a pure function so
    /// the SP-002 gate-diagnostics tests can replay audio through the exact
    /// arithmetic the pipeline uses.
    static func compute(from samples: [Float]) -> AudioStats {
        guard !samples.isEmpty else {
            return AudioStats(
                rms: 0,
                peak: 0,
                activeRatio: 0,
                speechWindowRatio: 0,
                strongWindowRatio: 0,
                noiseFloorRMS: 0,
                dynamicRangeDB: 0,
                crestFactor: 0
            )
        }

        var sumSquares: Float = 0
        var peak: Float = 0
        for sample in samples {
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
        }

        var windowRMS: [Float] = []
        var activeWindows = 0
        var totalWindows = 0
        var start = 0
        while start + probeSamples <= samples.count {
            totalWindows += 1
            let window = rms(samples, from: start, count: probeSamples)
            windowRMS.append(window)
            if window >= pauseRMS {
                activeWindows += 1
            }
            start += probeSamples
        }

        let noiseFloor = percentile(windowRMS, fraction: 0.20)
        let loudFloor = percentile(windowRMS, fraction: 0.90)
        let speechThreshold = max(pauseRMS, noiseFloor * 2.4, 0.012)
        let strongThreshold = max(noiseFloor * 3.2, 0.020)
        let speechWindows = windowRMS.filter { $0 >= speechThreshold }.count
        let strongWindows = windowRMS.filter { $0 >= strongThreshold }.count
        let activeRatio = totalWindows > 0 ? Float(activeWindows) / Float(totalWindows) : 0
        let speechRatio = totalWindows > 0 ? Float(speechWindows) / Float(totalWindows) : 0
        let strongRatio = totalWindows > 0 ? Float(strongWindows) / Float(totalWindows) : 0
        let dynamicRange = 20 * log10(max(loudFloor, 0.000_001) / max(noiseFloor, 0.000_001))
        let totalRMS = (sumSquares / Float(samples.count)).squareRoot()
        return AudioStats(
            rms: totalRMS,
            peak: peak,
            activeRatio: activeRatio,
            speechWindowRatio: speechRatio,
            strongWindowRatio: strongRatio,
            noiseFloorRMS: noiseFloor,
            dynamicRangeDB: dynamicRange,
            crestFactor: peak / max(totalRMS, 0.000_001)
        )
    }

    /// RMS of the `count` samples starting at `start`.
    static func rms(_ samples: [Float], from start: Int, count: Int) -> Float {
        var sumSquares: Float = 0
        for i in start..<(start + count) { sumSquares += samples[i] * samples[i] }
        return (sumSquares / Float(count)).squareRoot()
    }

    private static func percentile(_ values: [Float], fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = min(max(fraction, 0), 1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }
}

/// Dashboard-facing lifecycle of the speech (Whisper) model — the models
/// banner's row for "which model is this, what is it doing right now".
/// Mirrors `SummaryModelState`; `ready` here means loaded and transcribing-
/// capable (Whisper is compiled into memory at launch, unlike the LLM).
enum SpeechModelState: Equatable {
    case loading
    case downloading(Double)   // fraction ∈ [0, 1]
    case ready
    case failed(String)
}

actor TranscriptionPipeline {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "TranscriptionPipeline")

    // MARK: - Tuning

    /// Don't cut (or transcribe) anything shorter than this — keeps chunks from
    /// becoming a stream of one-word slivers when there are lots of short pauses.
    private let minSamples = Int(AudioConstants.sampleRate * 1)
    /// Hard cap: if someone talks nonstop, force a cut at the quietest point
    /// within the last few seconds rather than waiting forever. Whisper tops out
    /// around 30 s/window; 12 s keeps latency reasonable while leaving margin.
    private let maxSamples = Int(AudioConstants.sampleRate * 12)

    // VAD endpointing — what counts as "the speaker stopped".

    /// Endpointing shares its probe window and non-speech floor with the
    /// gate-metric computation (`AudioStats`), so pauses and speech windows
    /// are measured identically.
    private let probeSamples = AudioStats.probeSamples
    private let pauseRMS = AudioStats.pauseRMS
    /// A trailing run of silence this long marks the end of an utterance, so we
    /// cut here. 0.5 s clears normal between-word gaps (<200 ms) but catches
    /// clause/sentence boundaries.
    private let endpointSilence = Int(AudioConstants.sampleRate * 0.5)
    /// Live transcript previews are re-run on a rolling window while we wait for
    /// a clean endpoint. They are UI-only and get replaced by final segments.
    private let partialMinSamples = Int(AudioConstants.sampleRate * 1.25)
    private let partialWindowSamples = Int(AudioConstants.sampleRate * 5)
    private let partialUpdateSamples = Int(AudioConstants.sampleRate * 1.25)

    // MARK: - Models

    /// WhisperKit model variant. Despite the folder id, this checkpoint is
    /// large-v3-TURBO (the v20240930 4-layer-decoder release), mixed-bit
    /// quantized to 626 MB — never rename the id, it is the on-disk contract.
    private let modelVariant = "large-v3-v20240930_626MB"
    /// Human name + size for the models banner. Honest surfaces (SP-005 user
    /// story 17): the display name says "turbo" because that is what runs —
    /// plain "large-v3" would claim an accuracy class the live model isn't.
    /// The full large-v3 exists only as the final-pass model
    /// (`FinalPassModelManager.modelDisplayName`).
    static let modelDisplayName = "Whisper large-v3-turbo"
    static let modelDisplaySize = "626 MB"

    /// Reports model-lifecycle transitions to the controller for the models
    /// banner. The `RecordingState` status string stays the popover's channel;
    /// this one is typed so the UI can render progress bars and retry buttons.
    private var modelPhaseHandler: (@Sendable (SpeechModelState) -> Void)?

    func setModelPhaseHandler(_ handler: @Sendable @escaping (SpeechModelState) -> Void) {
        modelPhaseHandler = handler
        // Late subscription: reflect an already-finished load immediately so
        // the banner never sits on a stale "Loading".
        if loaded { handler(.ready) }
    }

    private var whisper: WhisperKit?
    private var loaded = false
    private var loadTask: Task<Void, Never>?
    private var detectedLanguages: [AudioChannel: String] = [:]
    /// Shared with the final pass (SP-005): live and final decodes restrict
    /// to the same language whitelist.
    static let allowedTranscriptionLanguages: Set<String> = ["en", "es"]

    /// The live path's decode options — also the final pass's v0 baseline
    /// (SP-005 S1; later slices diverge on retries/temperature fallback).
    static let liveDecodeOptions: DecodingOptions = {
        var options = DecodingOptions()
        options.verbose = false
        options.task = .transcribe
        options.temperatureFallbackCount = 0
        options.compressionRatioThreshold = 2.2
        options.logProbThreshold = -0.75
        options.firstTokenLogProbThreshold = -1.2
        options.noSpeechThreshold = 0.45
        options.detectLanguage = false
        options.wordTimestamps = false
        options.skipSpecialTokens = true   // keep <|...|> tokens out of the text
        return options
    }()

    // MARK: - State

    private weak var state: RecordingState?

    /// Per-channel pending audio plus the recording-relative time of its first
    /// sample, so emitted segments keep absolute timestamps as we drain it.
    private struct ChannelBuffer {
        var samples: [Float] = []
        var chunkStart: TimeInterval = 0
        var lastPartialSampleCount = 0
        var partialGeneration = 0
        var partialInFlight = false
        var partialRequestID = 0
    }

    private struct PartialSnapshot {
        let audio: [Float]
        let stats: AudioStats
        let offset: TimeInterval
        let sessionGeneration: Int
        let bufferGeneration: Int
        let requestID: Int
    }

    private var mic = ChannelBuffer()
    private var system = ChannelBuffer()
    private var sessionGeneration = 0
    private var nextPartialRequestID = 0

    /// Receives one record per finalized-chunk gate decision (SP-002 US-12).
    private let gateDiagnostics: any GateDiagnosticsSink

    /// The sink defaults to the permanent os.Logger diagnostic; tests and the
    /// input-health classifier (ADR-006) inject their own to observe gate
    /// decisions in-process.
    init(gateDiagnostics: any GateDiagnosticsSink = OSLogGateDiagnosticsSink()) {
        self.gateDiagnostics = gateDiagnostics
    }

    private static func speaker(for channel: AudioChannel) -> Speaker {
        channel == .microphone ? .me : .teammates
    }

    private func pendingSamples(_ channel: AudioChannel) -> [Float] {
        switch channel {
        case .microphone: return mic.samples
        case .system: return system.samples
        }
    }

    private func append(_ frames: [Float], to channel: AudioChannel) {
        switch channel {
        case .microphone: mic.samples.append(contentsOf: frames)
        case .system: system.samples.append(contentsOf: frames)
        }
    }

    /// Synchronously pulls the leading `count` samples off a channel buffer and
    /// advances its clock. No `await` runs between the read and the mutation, so
    /// reentrant `ingest` calls can't observe a torn buffer.
    private func detachChunk(_ channel: AudioChannel, count: Int) -> (chunk: [Float], offset: TimeInterval)? {
        switch channel {
        case .microphone: return Self.detach(&mic, count)
        case .system: return Self.detach(&system, count)
        }
    }

    private static func detach(_ buffer: inout ChannelBuffer, _ count: Int) -> (chunk: [Float], offset: TimeInterval)? {
        let n = min(count, buffer.samples.count)
        guard n > 0 else { return nil }
        let chunk = Array(buffer.samples.prefix(n))
        buffer.samples.removeFirst(n)
        let offset = buffer.chunkStart
        buffer.chunkStart += Double(n) / AudioConstants.sampleRate
        return (chunk, offset)
    }

    private func invalidatePartial(for channel: AudioChannel) -> Int {
        switch channel {
        case .microphone:
            return Self.invalidatePartial(&mic)
        case .system:
            return Self.invalidatePartial(&system)
        }
    }

    private static func invalidatePartial(_ buffer: inout ChannelBuffer) -> Int {
        buffer.partialGeneration += 1
        buffer.lastPartialSampleCount = 0
        return buffer.partialGeneration
    }

    private func preparePartialSnapshot(for channel: AudioChannel) -> PartialSnapshot? {
        let buffer: ChannelBuffer
        switch channel {
        case .microphone:
            buffer = mic
        case .system:
            buffer = system
        }

        let sampleCount = buffer.samples.count
        guard sampleCount >= partialMinSamples else { return nil }
        guard !buffer.partialInFlight else { return nil }
        guard sampleCount - buffer.lastPartialSampleCount >= partialUpdateSamples else { return nil }

        let windowCount = min(sampleCount, partialWindowSamples)
        let windowStart = sampleCount - windowCount
        let audio = Array(buffer.samples[windowStart..<sampleCount])
        let stats = AudioStats.compute(from: audio)
        guard Self.shouldTranscribe(stats, from: channel) else { return nil }

        nextPartialRequestID += 1
        let requestID = nextPartialRequestID
        switch channel {
        case .microphone:
            mic.partialInFlight = true
            mic.partialRequestID = requestID
            mic.lastPartialSampleCount = sampleCount
        case .system:
            system.partialInFlight = true
            system.partialRequestID = requestID
            system.lastPartialSampleCount = sampleCount
        }

        return PartialSnapshot(
            audio: audio,
            stats: stats,
            offset: buffer.chunkStart + Double(windowStart) / AudioConstants.sampleRate,
            sessionGeneration: sessionGeneration,
            bufferGeneration: buffer.partialGeneration,
            requestID: requestID
        )
    }

    private func finishPartial(
        for channel: AudioChannel,
        snapshot: PartialSnapshot,
        segment: TranscriptSegment?
    ) async {
        let isCurrent: Bool
        switch channel {
        case .microphone:
            guard mic.partialRequestID == snapshot.requestID else { return }
            mic.partialInFlight = false
            isCurrent = sessionGeneration == snapshot.sessionGeneration
                && mic.partialGeneration == snapshot.bufferGeneration
        case .system:
            guard system.partialRequestID == snapshot.requestID else { return }
            system.partialInFlight = false
            isCurrent = sessionGeneration == snapshot.sessionGeneration
                && system.partialGeneration == snapshot.bufferGeneration
        }

        guard isCurrent else { return }
        if let segment {
            await state?.updatePartial(
                segment,
                sessionGeneration: snapshot.sessionGeneration,
                generation: snapshot.bufferGeneration,
                requestID: snapshot.requestID
            )
        } else {
            await state?.clearPartial(
                for: channel,
                sessionGeneration: snapshot.sessionGeneration,
                generation: snapshot.bufferGeneration,
                requestID: snapshot.requestID
            )
        }
    }

    // MARK: - Lifecycle

    /// Loads the models (downloading on first run). Idempotent and safe to call
    /// from app launch so the heavy work is done before the user hits record.
    /// Concurrent callers share (and await) a single in-flight load.
    func preload(updating state: RecordingState) async {
        self.state = state
        if loaded { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await self.performLoad() }
        loadTask = task
        await task.value
        if !loaded { loadTask = nil }   // allow a retry after a failed load
    }

    private func performLoad() async {
        let clock = ContinuousClock()
        let started = clock.now
        let stateRef = state
        let phase = modelPhaseHandler
        do {
            // 0. Single-data-root rule: WhisperKit historically downloaded to
            //    swift-transformers' default (~/Documents/huggingface). Move
            //    any existing cache under EchoPaths once — no re-download —
            //    then pin every download below to the same base.
            EchoPaths.migrateLegacyWhisperKitCacheIfNeeded()

            // 1. Resolve the model, preferring the local snapshot: a complete
            //    cache loads with ZERO network. `WhisperKit.download` always
            //    hits the Hub API first, so a launch with no connectivity —
            //    or with a stale ~/.cache/huggingface token the Hub rejects
            //    (observed 2026-07-21: an expired OAuth token 401'd every
            //    launch) — would fail the whole load while the model sat
            //    fully cached on disk. Local-first means the network is only
            //    touched when something is actually missing.
            let folder: URL
            if let cached = Self.cachedModelFolder(for: modelVariant) {
                folder = cached
            } else {
                // First run (or partial cache): download with progress. A
                // stalled download is cancelled and retried instead of
                // hanging the pipeline at its last percentage forever.
                await state?.updateStatus("Downloading speech model…")
                phase?(.downloading(0))
                let variant = modelVariant
                folder = try await ModelDownload.withStallRetry(
                    onRetry: { attempt in
                        Self.log.warning("Whisper model download stalled; retrying (attempt \(attempt, privacy: .public))")
                        Task { @MainActor in
                            stateRef?.updateStatus("Download stalled — retrying…")
                        }
                    }
                ) { noteProgress in
                    try await WhisperKit.download(
                        variant: variant,
                        downloadBase: EchoPaths.modelsDirectory,
                        useBackgroundSession: false
                    ) { progress in
                        noteProgress(progress.fractionCompleted)
                        phase?(.downloading(progress.fractionCompleted))
                        Task { @MainActor in
                            stateRef?.updateStatus("Downloading speech model… \(Int(progress.fractionCompleted * 100))%")
                        }
                    }
                }
            }

            // 2. Compile + load from the local folder (no model re-download;
            //    download:true only lets the tokenizer resolve if needed —
            //    tokenizerFolder pins that resolve under EchoPaths too).
            await state?.updateStatus("Loading speech model…")
            phase?(.loading)
            whisper = try await WhisperKit(
                modelFolder: folder.path,
                tokenizerFolder: EchoPaths.modelsDirectory,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: true
            )
            loaded = true
            Self.log.info("Model loaded in \(started.duration(to: clock.now).description, privacy: .public)")
            phase?(.ready)
            await state?.updateStatus("")
        } catch {
            ErrorTrace.record("Speech model load failed", error: error, category: "TranscriptionPipeline")
            phase?(.failed(error.localizedDescription))
            await state?.updateStatus("Couldn't load speech model: \(error.localizedDescription)")
        }
    }

    /// Whether the transcriber is actually usable — `ingest` drops all audio
    /// until it is. The controller surfaces this at session start so a failed
    /// model load can never masquerade as "Transcribing…".
    var isReady: Bool { loaded }

    /// Whether recording right now would first require fetching the model
    /// from the network: nothing is loaded and no complete local snapshot
    /// exists. Deliberately `false` during a cache-only load — that resolves
    /// in seconds, so a session may simply await it as it always has.
    var needsModelDownload: Bool {
        !loaded && Self.cachedModelFolder(for: modelVariant) == nil
    }

    /// The complete local snapshot for `variant`, or nil when any required
    /// artifact is missing (a partial cache falls through to the resumable
    /// download path). Mirrors WhisperKit's repo layout under the app's
    /// single data root: models/argmaxinc/whisperkit-coreml/<model>, where
    /// <model> is "openai_whisper-" + variant.
    private static func cachedModelFolder(for variant: String) -> URL? {
        let repoDirectory = EchoPaths.modelsDirectory
            .appending(path: "models/argmaxinc/whisperkit-coreml")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: repoDirectory.path),
              let name = entries.first(where: { $0.hasSuffix(variant) })
        else { return nil }

        let folder = repoDirectory.appending(path: name)
        // The compiled Core ML bundles WhisperKit loads, plus its config.
        let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "config.json"]
        for artifact in required {
            guard fm.fileExists(atPath: folder.appending(path: artifact).path) else { return nil }
        }
        return folder
    }

    /// Resets per-session state and ensures the models are loaded.
    func start(appendingTo state: RecordingState) async {
        self.state = state
        sessionGeneration += 1
        detectedLanguages.removeAll()
        mic = ChannelBuffer()
        system = ChannelBuffer()
        await state.beginPartialSession(sessionGeneration)

        if !loaded { await preload(updating: state) }
    }

    #if DEBUG
    /// Test seam (SP-002 S1): marks the pipeline ready to ingest without a
    /// Whisper model, so gate-diagnostics tests can drive the real
    /// ingest → endpoint → gate path. Chunks the gate drops never reach the
    /// transcriber, and `emit`/`maybeEmitPartial` already tolerate a nil
    /// `whisper`, so nothing is mocked. Production readiness only ever comes
    /// from `preload`.
    func prepareForGateTestingWithoutTranscriber() {
        loaded = true
    }
    #endif

    /// Flush whatever is left in both buffers at the end of the session.
    func stop() async {
        sessionGeneration += 1
        await state?.clearPartials(sessionGeneration: sessionGeneration)
        await emit(.microphone, count: mic.samples.count)
        await emit(.system, count: system.samples.count)
        detectedLanguages.removeAll()
        await state?.clearPartials(sessionGeneration: sessionGeneration)
    }

    // MARK: - Final-pass decode seam (SP-005 S1)

    /// Lends the already-loaded live WhisperKit instance to a final-pass
    /// decode (ADR-015's floor tier: the pass adds no model to memory). The
    /// narrow seam `LivePipelineModelProvider` is built on — the final pass
    /// never reaches into the pipeline's buffers, clocks, or session state,
    /// and nothing here can disturb live behavior.
    func withModelForFinalPass<T: Sendable>(
        _ body: @Sendable (WhisperKit) async throws -> T
    ) async throws -> T {
        guard loaded, let whisper else { throw FinalizationPass.PassError.modelUnavailable }
        return try await body(whisper)
    }

    // MARK: - Ingestion

    func ingest(_ frames: [Float], from channel: AudioChannel) async {
        guard loaded else { return }   // drop audio until the models are ready
        append(frames, to: channel)
        // Emit every chunk whose boundary is currently exposed (a long pause may
        // free several at once after a backlog).
        while let cut = cutPoint(pendingSamples(channel)) {
            await emit(channel, count: cut)
        }
        await maybeEmitPartial(channel)
    }

    // MARK: - Capture-gap clock realignment (SP-002 "input switch mid-recording")

    /// Advances `channel`'s clock past a measured capture gap — wall time in
    /// which the channel captured nothing (a device-switch engine rebuild, a
    /// lost-device episode). The clock otherwise advances purely by ingested
    /// sample count, so an unreported gap would lag every later timestamp on
    /// this channel by the gap duration, cumulatively across switches —
    /// breaking SP-001's 100 ms cross-channel skew budget and the cross-channel
    /// alignment ADR-003's 2.5 s dedup timing gate depends on.
    ///
    /// Samples pending when the gap is declared (the mic died mid-utterance)
    /// are force-finalized as their own pre-gap chunk rather than left to
    /// merge with post-gap audio: a merged chunk would hand Whisper one
    /// splice whose within-chunk timestamps place every post-gap word up to
    /// the full gap too early and whose recorded duration misstates its wall
    /// span — exactly the mis-attributed segment starts ADR-003's timing
    /// gate cannot survive. The device was dead in between, so the two spans
    /// are separate utterances anyway. The flush takes the normal
    /// gate → transcribe path (like the end-of-session flush in `stop()`,
    /// which already emits sub-`minSamples` chunks), so declared gaps never
    /// lose pre-gap audio.
    ///
    /// Channel-scoped and additive: the other channel is never touched, and a
    /// session that never declares a gap behaves exactly as before.
    func noteCaptureGap(seconds: TimeInterval, on channel: AudioChannel) async {
        // Mirrors `ingest`: audio is dropped until the models are ready, and
        // while both channels drop audio their clocks are frozen together, so
        // a pre-load gap must be dropped too or it would *introduce* skew.
        guard loaded else { return }
        // Only real dead time may move a clock, and never backward: monotonic
        // segment timestamps are part of the SP-002 switch criterion. Also
        // rejects NaN/infinity from a broken measurement.
        guard seconds > 0, seconds.isFinite else { return }

        // Detach the pre-gap audio and advance the clock with no `await` in
        // between (same discipline as `detachChunk`): a reentrant `ingest`
        // can only ever observe the clock fully pre-gap or fully post-gap,
        // never a pending buffer straddling a half-applied gap.
        let pending = detachChunk(channel, count: pendingSamples(channel).count)
        advanceClock(by: seconds, on: channel)
        Self.log.info("""
        \(channel.rawValue, privacy: .public) capture gap: clock advanced by \
        \(String(format: "%.3f", seconds), privacy: .public)s\
        \(pending == nil ? "" : ", pending pre-gap audio finalized", privacy: .public)
        """)
        if let pending {
            await finalize(pending.chunk, at: pending.offset, on: channel)
        }
    }

    private func advanceClock(by seconds: TimeInterval, on channel: AudioChannel) {
        switch channel {
        case .microphone: mic.chunkStart += seconds
        case .system: system.chunkStart += seconds
        }
    }

    // MARK: - VAD endpointing

    /// Decides where (if anywhere) the pending buffer should be cut right now.
    /// Returns the number of leading samples to emit, or `nil` to keep buffering.
    private func cutPoint(_ samples: [Float]) -> Int? {
        guard samples.count >= minSamples else { return nil }

        // Natural endpoint: the speaker paused. Cut at the end of the buffer so
        // the whole utterance (plus its trailing silence) goes out together.
        if trailingSilence(samples) >= endpointSilence { return samples.count }

        // Nonstop talking: force a cut at the quietest window we can find near
        // the end, which is the least-bad place to split mid-speech.
        if samples.count >= maxSamples { return quietestCut(samples) }

        return nil
    }

    /// Length, in samples, of the uninterrupted low-energy run at the buffer's end.
    private func trailingSilence(_ samples: [Float]) -> Int {
        var silent = 0
        var end = samples.count
        while end - probeSamples >= 0 {
            if AudioStats.rms(samples, from: end - probeSamples, count: probeSamples) >= pauseRMS { break }
            silent += probeSamples
            end -= probeSamples
        }
        return silent
    }

    /// Index of the quietest probe window in the last few seconds — used as the
    /// fallback cut when there's no real pause. Never cuts below `minSamples`.
    private func quietestCut(_ samples: [Float]) -> Int {
        let searchSpan = Int(AudioConstants.sampleRate * 4)
        let lo = max(minSamples, samples.count - searchSpan)
        let hi = samples.count - probeSamples
        guard hi > lo else { return samples.count }

        var bestRMS = Float.greatestFiniteMagnitude
        var bestCut = samples.count
        var i = lo
        while i <= hi {
            let value = AudioStats.rms(samples, from: i, count: probeSamples)
            if value < bestRMS {
                bestRMS = value
                bestCut = i + probeSamples / 2   // cut through the middle of the gap
            }
            i += probeSamples
        }
        return bestCut
    }

    // MARK: - Transcription

    private func maybeEmitPartial(_ channel: AudioChannel) async {
        guard let whisper else { return }
        guard let snapshot = preparePartialSnapshot(for: channel) else { return }

        let segment: TranscriptSegment?
        do {
            guard let language = await cachedOrRestrictedLanguage(for: snapshot.audio, from: channel, using: whisper) else {
                await finishPartial(for: channel, snapshot: snapshot, segment: nil)
                return
            }
            var options = Self.liveDecodeOptions
            options.language = language
            let results = try await whisper.transcribe(audioArray: snapshot.audio, decodeOptions: options)
            segment = partialSegment(from: results, channel: channel, offset: snapshot.offset, stats: snapshot.stats)
        } catch {
            ErrorTrace.record(
                "Partial transcribe failed",
                error: error,
                category: "TranscriptionPipeline",
                metadata: ["channel": channel.rawValue]
            )
            segment = nil
        }

        await finishPartial(for: channel, snapshot: snapshot, segment: segment)
    }

    /// Pulls the leading `count` samples off the channel buffer, transcribes
    /// them, and appends the resulting segments. Shared by both channels.
    private func emit(_ channel: AudioChannel, count: Int) async {
        guard let (chunk, offset) = detachChunk(channel, count: count) else { return }
        await finalize(chunk, at: offset, on: channel)
    }

    /// Runs an already-detached chunk through partial invalidation, the gate
    /// decision (recording it — SP-002 US-12), and transcription. Split from
    /// `emit` so the capture-gap path can detach pre-gap audio and advance
    /// the clock synchronously before this suspends.
    private func finalize(_ chunk: [Float], at offset: TimeInterval, on channel: AudioChannel) async {
        let partialGeneration = invalidatePartial(for: channel)
        await state?.clearPartial(
            for: channel,
            sessionGeneration: sessionGeneration,
            generation: partialGeneration
        )

        let stats = AudioStats.compute(from: chunk)
        // One diagnostic record per finalized-chunk gate decision, for both
        // verdicts (SP-002 US-12). Partial-preview gate checks are deliberately
        // not recorded: they re-measure rolling windows of this same audio and
        // would double-count it for the input-health classifier (ADR-006).
        let decision = GateDecisionRecord(
            channel: channel,
            chunkDuration: Double(chunk.count) / AudioConstants.sampleRate,
            chunkStartOffset: offset,
            stats: stats
        )
        gateDiagnostics.record(decision)
        guard decision.verdict == .transcribe else { return }
        guard let whisper else { return }
        let results: [TranscriptionResult]
        do {
            guard let language = await restrictedLanguage(for: chunk, from: channel, using: whisper) else { return }
            var options = Self.liveDecodeOptions
            options.language = language
            results = try await whisper.transcribe(audioArray: chunk, decodeOptions: options)
        } catch {
            ErrorTrace.record(
                "Transcribe failed",
                error: error,
                category: "TranscriptionPipeline",
                metadata: ["channel": channel.rawValue]
            )
            return
        }
        for segment in Self.transcriptSegments(from: results, channel: channel, offset: offset, stats: stats) {
            await state?.append(segment)
        }
    }

    private func partialSegment(
        from results: [TranscriptionResult],
        channel: AudioChannel,
        offset: TimeInterval,
        stats: AudioStats
    ) -> TranscriptSegment? {
        let segments = Self.transcriptSegments(from: results, channel: channel, offset: offset, stats: stats)
        guard let first = segments.first, let last = segments.last else { return nil }

        return TranscriptSegment(
            channel: channel,
            speaker: Self.speaker(for: channel),
            text: segments.map(\.text).joined(separator: " "),
            start: first.start,
            end: last.end
        )
    }

    /// Static (pure) so the final pass (SP-005) assembles and filters its
    /// segments through exactly the live path's logic.
    static func transcriptSegments(
        from results: [TranscriptionResult],
        channel: AudioChannel,
        offset: TimeInterval,
        stats: AudioStats
    ) -> [TranscriptSegment] {
        let who = speaker(for: channel)
        var segments: [TranscriptSegment] = []
        for result in results {
            for segment in result.segments {
                guard let segmentText = cleaned(segment.text, channel: channel, segment: segment, audio: stats) else { continue }
                segments.append(TranscriptSegment(
                    channel: channel,
                    speaker: who,
                    text: segmentText,
                    start: offset + Double(segment.start),
                    end: offset + Double(segment.end)
                ))
            }
        }
        return segments
    }

    private func cachedOrRestrictedLanguage(for audio: [Float], from channel: AudioChannel, using whisper: WhisperKit) async -> String? {
        if let language = detectedLanguages[channel] { return language }
        return await restrictedLanguage(for: audio, from: channel, using: whisper)
    }

    private func restrictedLanguage(for audio: [Float], from channel: AudioChannel, using whisper: WhisperKit) async -> String? {
        do {
            let detection = try await whisper.detectLangauge(audioArray: audio)
            guard Self.allowedTranscriptionLanguages.contains(detection.language) else {
                detectedLanguages[channel] = nil
                Self.log.info("\(channel.rawValue, privacy: .public) skipped unsupported detected language: \(detection.language, privacy: .public)")
                return nil
            }
            detectedLanguages[channel] = detection.language
            return detection.language
        } catch {
            ErrorTrace.record(
                "Language detection failed",
                error: error,
                category: "TranscriptionPipeline",
                metadata: ["channel": channel.rawValue]
            )
            return nil
        }
    }

    private static func cleaned(
        _ text: String,
        channel: AudioChannel,
        segment: TranscriptionSegment,
        audio: AudioStats
    ) -> String? {
        // Strip any leftover Whisper special tokens (e.g. <|0.00|>, <|en|>).
        var value = text.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        )
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // Whisper emits these markers on silence/non-speech — drop them.
        let nonSpeech: Set<String> = [
            "[blank_audio]", "[silence]", "[ silence ]", "(silence)",
            "[no speech]", "[music]", "(music)", "[inaudible]", "[ pause ]",
        ]
        let lowercased = value.lowercased()
        if nonSpeech.contains(lowercased) { return nil }
        if isLikelyNoiseTranscription(value, channel: channel, segment: segment, audio: audio) { return nil }
        if isLikelyWhisperBoilerplate(value, segment: segment, audio: audio) { return nil }

        return value
    }

    private static func isLikelyNoiseTranscription(
        _ text: String,
        channel: AudioChannel,
        segment: TranscriptionSegment,
        audio: AudioStats
    ) -> Bool {
        let words = normalizedWords(text)
        guard !words.isEmpty else { return true }

        let lowConfidence = segment.avgLogprob < -0.70
            || segment.compressionRatio > 2.2
            || segment.noSpeechProb > 0.45
        let short = words.count <= 5 || segment.duration <= 1.4
        let veryShort = words.count <= 2 || segment.duration <= 0.8
        let garbled = unsupportedLetterRatio(in: text) >= 0.12

        if !shouldTranscribe(audio, from: channel) { return true }
        if veryShort && (lowConfidence || audio.isMarginalSpeech) { return true }
        if short && lowConfidence && audio.isMarginalSpeech { return true }
        if garbled && (lowConfidence || audio.isMarginalSpeech || short) { return true }

        return false
    }

    private static func isLikelyWhisperBoilerplate(
        _ text: String,
        segment: TranscriptionSegment,
        audio: AudioStats
    ) -> Bool {
        let normalized = normalizedWords(text).joined(separator: " ")
        guard !normalized.isEmpty else { return true }

        let commonHallucinations: Set<String> = [
            "i know", "you know", "thank you", "thank you very much",
            "thanks", "thanks you", "thanks for watching", "thank you for watching",
            "ok", "okay", "yeah", "yes", "right", "all right",
            "bye", "bye bye", "goodbye", "hello", "hi",
            "from below", "but im not", "but i m not", "im not sure", "i m not sure",
            "happy birthday", "gracias",
            "you", "so", "um", "uh", "mhm", "mm hmm", "uh huh",
        ]

        guard commonHallucinations.contains(normalized) else { return false }

        let short = segment.duration <= 1.6 || normalizedWords(text).count <= 4
        let lowConfidence = segment.avgLogprob < -0.55 || segment.compressionRatio > 2.2
        return short && (!audio.hasClearSpeech || lowConfidence)
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// True only when the audio has enough speech-like structure to be worth
    /// sending to Whisper. This is intentionally stricter than a silence check:
    /// high ambient noise can be loud, but it should not become transcript text.
    /// Delegates to the term-level evaluation in `GateDiagnostics.swift` so the
    /// per-chunk diagnostics (SP-002 US-12) describe this exact decision.
    private static func shouldTranscribe(_ stats: AudioStats, from channel: AudioChannel) -> Bool {
        GateDecisionRecord.verdict(for: stats, on: channel) == .transcribe
    }

    private static func unsupportedLetterRatio(in text: String) -> Double {
        let allowedLetters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZáéíóúüñÁÉÍÓÚÜÑ")
        var totalLetters = 0
        var unsupportedLetters = 0

        for scalar in text.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else { continue }
            totalLetters += 1
            if !allowedLetters.contains(scalar) {
                unsupportedLetters += 1
            }
        }

        guard totalLetters > 0 else { return 0 }
        return Double(unsupportedLetters) / Double(totalLetters)
    }
}
