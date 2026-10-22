//
//  TranscriptionPass.swift
//  Transcription
//
//  THE transcription pass. After a meeting stops, the retained per-channel
//  audio is decoded once, end to end, on `parakeet-tdt-0.6b-v3` through
//  FluidAudio. There is no live transcript to improve on and no "floor" to
//  fall back to — this pass is where a meeting's words come from.
//
//  Deliberately thin, and that is the point. Whisper's pass needed per-window
//  language detection, A/B dual decodes, prompt chaining, rejection
//  thresholds, energy evidence gates, run collapse and tail pads — every one
//  of them a defense against a pathology of that model, and two of them
//  (the A/B verdict, the evidence gate) measured on 2026-08-06 to be
//  translating Spanish into English and erasing real speech. Parakeet v3 has
//  none of those failure modes, so this pass has none of those defenses:
//  read → transcribe → map timings to segments → dedup. Nothing else belongs
//  here; if quality disappoints, the model choice is what changes, never a
//  compensating heuristic bolted on below.
//
//  Long audio is FluidAudio's problem, not ours: `AsrManager.transcribe`
//  chunks internally at ~15 s frame-aligned windows with overlap and merges
//  the result, and streams a progress fraction for anything over ~15 s. The
//  model is loaded ONCE per pass (never per window — the old pass's
//  per-window reload was a measured defect) and released when the pass ends.
//
//  Speaker is the channel, never diarization: the microphone is You and the
//  system audio is Others, decided before a single token is read.
//

import AVFoundation
import EchoCore
import FluidAudio
import Foundation
import os

public enum TranscriptionPass {

    static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "TranscriptionPass")

    /// The rate the model consumes and the rate capture downmixes to. It is
    /// the model's input contract, which is why it lives here rather than
    /// being borrowed from the capture package the pass must not depend on;
    /// it has to stay equal to `Audio`'s canonical format.
    public static let sampleRate: Double = 16_000

    // MARK: Segment shaping

    /// Split the token stream at any inter-token silence longer than this. The
    /// model emits per-token times, not sentences, so this is what turns a
    /// channel's tokens into readable, timeline-anchored segments.
    ///
    /// It is also the finest grain the dedup can work at, which is what set
    /// this value. A segment is the unit of suppression, so any silence this
    /// misses welds real speech to the bleed that follows it into one
    /// indivisible row — kept whole with the echo inside, or deleted whole
    /// with the speech. Measured on a field recording: a 0.7 s pause between
    /// the user finishing and the teammate's echo starting, which 1.0 s
    /// stepped straight over. Splitting there costs nothing the reader sees
    /// (`TranscriptUtterance.derive` re-merges same-speaker runs) and lets
    /// each side be judged on its own evidence.
    public static let segmentGapSeconds: TimeInterval = 0.6

    /// A silent stretch in the channel's OWN audio at least this long also
    /// ends a segment, whatever the token timings say.
    ///
    /// `segmentGapSeconds` trusts the model's estimate of when it heard each
    /// token, and that estimate is what fails on the case this exists for: a
    /// measured 0.7 s pause between the user finishing and an echo starting,
    /// which the model papered over by stretching its token times across it —
    /// no gap to split on, so real speech and bleed stayed welded into one
    /// row. The audio always knew. Shorter than `segmentGapSeconds` because
    /// this is positive evidence of silence rather than the mere absence of a
    /// token, and because the token boundaries either side eat into it.
    public static let silenceSplitSeconds: TimeInterval = 0.3

    /// A running segment longer than this splits at the next word start —
    /// mirroring the 1–12 s granularity the rest of the app (dedup timing
    /// gate, transcript UI, summary chunking) was built against.
    public static let maxSegmentSeconds: TimeInterval = 12.0

    /// Polling period of the preemption watcher: the pass yields promptly
    /// once a recording starts.
    public static let yieldPollInterval: Duration = .milliseconds(250)

    /// Decodes every retained channel and returns the complete segment set,
    /// timeline-ordered, ready for the atomic write. Throws on any failure —
    /// the caller keeps the retained audio and decides retry vs terminal.
    /// `onProgress` receives the single clamped, monotonic fraction.
    ///
    /// The pass neither deletes retained audio nor writes anything: what
    /// happens to the files and to `Meetings/` is the caller's decision.
    public static func run(
        retainedFiles: [AudioChannel: URL],
        model: ParakeetModel,
        shouldYield: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (Double) -> Void = { _ in },
        onEvent: (@Sendable (PassEvent) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        // Deterministic channel order; the sort below owns the timeline.
        let channels = [AudioChannel.microphone, .system].compactMap { channel in
            retainedFiles[channel].map { (channel: channel, url: $0) }
        }

        guard let modelDirectory = await model.readyModelDirectory() else {
            throw TranscriptionError.modelUnavailable
        }
        // A recording that started while we were asking must not pay for a
        // model load it is about to preempt anyway.
        if shouldYield() { throw TranscriptionError.preempted }

        let asrModels: AsrModels
        do {
            asrModels = try await AsrModels.load(
                from: modelDirectory,
                version: ParakeetModel.version,
                encoderPrecision: ParakeetModel.encoderPrecision
            )
        } catch {
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }

        // `melChunkContext: false` is FluidAudio's own instruction for v3
        // multilingual long-form batch transcription (the 80 ms mel prepend
        // makes the SOS-primed decoder drift back to its English-biased prior
        // — exactly the Spanish-meetings case).
        //
        // `dualDecodeArbitration` is the other half of that same case. Left
        // off, the batch path chunks one way and merges the pieces; where the
        // chunks disagree the merger stitches, and the library reports the
        // artifacts as "mid-word duplicates and dropped clauses on
        // heterogeneous-confidence files like long Spanish narration". A
        // meeting is exactly that file: a Spanish speaker whose technical
        // nouns are English, so confidence moves span to span. Measured on
        // one, the share of unambiguous English function words on the You
        // channel fell from 17 % to 10 %. The residue is roughly what the
        // speaker really code-switches.
        //
        // It is confidence-based — no text inspection, no vocabulary or script
        // filtering, no language hint — which matters, because the hint
        // FluidAudio does expose partitions by Unicode script, and Spanish and
        // English are both Latin: it cannot reject a single English token and
        // would be a fix in name only.
        //
        // Everything else stays at library defaults. Two costs, both accepted:
        // the probe is documented at 1.1–1.5× and measured at 2.3× here (6.5 s
        // for a 6.5 min meeting, against a pass already budgeted in minutes),
        // and committing a file to one strategy still leaves the odd stitched
        // span where the probe was close.
        let manager = AsrManager(
            config: ASRConfig(
                melChunkContext: false,
                dualDecodeArbitration: true
            )
        )
        do {
            try await manager.loadModels(asrModels)
        } catch {
            await manager.cleanup()
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }

        do {
            let segments = try await transcribeChannels(
                channels,
                manager: manager,
                shouldYield: shouldYield,
                onProgress: onProgress,
                onEvent: onEvent
            )
            await manager.cleanup()
            return segments
        } catch {
            // Pass-scoped release on every exit — Swift forbids `await` in a
            // `defer`, so the release is driven from this do/catch instead.
            await manager.cleanup()
            throw error
        }
    }

    private static func transcribeChannels(
        _ channels: [(channel: AudioChannel, url: URL)],
        manager: AsrManager,
        shouldYield: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Double) -> Void,
        onEvent: (@Sendable (PassEvent) -> Void)?
    ) async throws -> [TranscriptSegment] {
        // One accumulator over both channels' retained durations drives every
        // fraction the UI sees — no second counter. Totals come from the
        // files' own lengths; a file this header can't open reads 0 here and
        // throws honestly when the channel is read below.
        let progress = SharedPassProgress(
            channelTotalSamples: channels.map {
                (try? AVAudioFile(forReading: $0.url)).map { Int($0.length) } ?? 0
            }
        )
        onProgress(progress.fraction)

        var segments: [TranscriptSegment] = []
        // The optional cross-channel evidence the dedup may use. Envelopes
        // outlive the samples they came from by design: an envelope costs
        // ~144 KB an hour, the samples ~46 MB, and one channel's buffer is
        // released before the next is read.
        var envelopes: [AudioChannel: EnergyEnvelope] = [:]
        for (index, entry) in channels.enumerated() {
            if shouldYield() { throw TranscriptionError.preempted }

            let samples = try readSamples(at: entry.url)
            let envelope = EnergyEnvelope(samples: samples)
            envelopes[entry.channel] = envelope
            let sampleCount = samples.count
            segments += try await transcribeChannel(
                samples: samples,
                channel: entry.channel,
                envelope: envelope,
                manager: manager,
                shouldYield: shouldYield,
                onChannelFraction: { fraction in
                    onProgress(
                        progress.advance(
                            channel: index,
                            decodedThrough: Int(fraction * Double(sampleCount))
                        )
                    )
                },
                onEvent: onEvent
            )
            onProgress(progress.finishChannel(index))
        }

        let ordered = segments.sorted { $0.start < $1.start }
        // Dedup over the complete set: the batch holds every Others segment,
        // so cross-channel echoes are caught here.
        let kept = EchoDedupPolicy().dedupe(
            final: ordered,
            spanLevels: spanLevels(of: ordered, envelopes: envelopes),
            onSuppression: onEvent.map { sink in
                { candidate, verdict in sink(.segmentSuppressed(suppression(candidate, verdict))) }
            }
        )
        // Numbers only — which rows went and why is the harness sink's job.
        log.notice(
            "Dedup: \(ordered.count - kept.count, privacy: .public) of \(ordered.count, privacy: .public) segments suppressed as bleed"
        )
        return kept
    }

    // MARK: Dedup evidence

    /// Both channels' rms over each segment's own window. Segment times are
    /// file-relative and the retained files begin at recording t=0, so a
    /// segment's span indexes both envelopes directly.
    ///
    /// A segment only carries evidence when BOTH channels can answer for its
    /// window — a half-measured span has no ratio, and the policy reads a
    /// missing entry as "no evidence, keep".
    public static func spanLevels(
        of segments: [TranscriptSegment],
        envelopes: [AudioChannel: EnergyEnvelope]
    ) -> [UUID: EchoDedupPolicy.SpanLevels] {
        var levels: [UUID: EchoDedupPolicy.SpanLevels] = [:]
        for segment in segments {
            let opposite: AudioChannel = segment.channel == .microphone ? .system : .microphone
            guard
                let ownEnvelope = envelopes[segment.channel],
                let otherEnvelope = envelopes[opposite],
                let own = ownEnvelope.rms(from: segment.start, to: segment.end),
                let other = otherEnvelope.rms(from: segment.start, to: segment.end)
            else { continue }
            levels[segment.id] = EchoDedupPolicy.SpanLevels(
                own: own,
                other: other,
                ownVoiceSeconds: ownEnvelope.longestDominantRun(
                    over: otherEnvelope,
                    from: segment.start,
                    to: segment.end
                )
            )
        }
        return levels
    }

    /// One structured record per suppressed segment: which tier fired and on
    /// what evidence, so a replay can show *why* a row went. Ids, times and
    /// scores only — a harness that wants the words holds the segments.
    private static func suppression(
        _ candidate: TranscriptSegment,
        _ verdict: EchoDedupPolicy.SuppressionVerdict
    ) -> PassEvent.Suppression {
        PassEvent.Suppression(
            segmentID: candidate.id,
            channel: candidate.channel,
            start: candidate.start,
            end: candidate.end,
            tier: verdict.tier,
            containment: verdict.containment,
            rmsRatio: verdict.rmsRatio,
            ownVoiceSeconds: verdict.ownVoiceSeconds,
            matchID: verdict.match.id,
            matchStart: verdict.match.start,
            matchEnd: verdict.match.end
        )
    }

    // MARK: Per-channel decode

    private static func transcribeChannel(
        samples: [Float],
        channel: AudioChannel,
        envelope: EnergyEnvelope,
        manager: AsrManager,
        shouldYield: @escaping @Sendable () -> Bool,
        onChannelFraction: @escaping @Sendable (Double) -> Void,
        onEvent: (@Sendable (PassEvent) -> Void)?
    ) async throws -> [TranscriptSegment] {
        guard !samples.isEmpty else { return [] }

        let clock = ContinuousClock()
        let started = clock.now
        let result = try await transcribeRespectingPreemption(
            samples: samples,
            manager: manager,
            shouldYield: shouldYield,
            onChannelFraction: onChannelFraction
        )

        let produced = segments(
            from: result.tokenTimings ?? [],
            text: result.text,
            duration: result.duration,
            channel: channel,
            silenceStarts: envelope.silenceStarts(minimum: silenceSplitSeconds)
        )
        let decode = PassEvent.ChannelDecode(
            channel: channel,
            audioSeconds: Double(samples.count) / sampleRate,
            tokenCount: result.tokenTimings?.count ?? 0,
            segmentCount: produced.count,
            decodeDuration: started.duration(to: clock.now)
        )
        // notice, not info: info-level lines never persist in the local log
        // store, so a field report arriving after the fact would find nothing.
        // Numbers only here — NEVER transcript text.
        log.notice(
            "Parakeet \(channel.rawValue, privacy: .public): \(decode.audioSeconds, privacy: .public)s audio, \(decode.tokenCount, privacy: .public) tokens → \(decode.segmentCount, privacy: .public) segments"
        )
        if let onEvent {
            onEvent(.channelDecoded(decode))
            for segment in produced {
                onEvent(
                    .segmentProduced(
                        id: segment.id,
                        channel: channel,
                        start: segment.start,
                        end: segment.end
                    )
                )
            }
        }
        return produced
    }

    /// Runs one channel's decode with preemption: a sibling watcher polls
    /// `shouldYield` and throws the moment a recording starts, which tears
    /// down the task group — FluidAudio checks `Task.isCancelled` inside its
    /// own chunk loop, so the decode stops within a chunk rather than running
    /// the meeting out.
    ///
    /// The decoder state is created inside the child task: it is per-channel
    /// (independent audio streams never share context) and `inout` can't cross
    /// a task boundary.
    private static func transcribeRespectingPreemption(
        samples: [Float],
        manager: AsrManager,
        shouldYield: @escaping @Sendable () -> Bool,
        onChannelFraction: @escaping @Sendable (Double) -> Void
    ) async throws -> ASRResult {
        // FluidAudio only opens a progress session for input over ~15 s
        // (`maxModelSamples`); subscribing below that would leave a session
        // nothing ever finishes. Subscribing BEFORE `transcribe` is the
        // library's documented order — buffered yields make it order-safe.
        let progressStream: AsyncThrowingStream<Double, Error>? =
            samples.count > ASRConstants.maxModelSamples
            ? await manager.transcriptionProgressStream
            : nil

        return try await withThrowingTaskGroup(of: ASRResult?.self) { group in
            group.addTask {
                var state = try TdtDecoderState(
                    decoderLayers: ParakeetModel.version.decoderLayers
                )
                // `language: nil` — neutral, the library default. The
                // meeting's language is not a stored fact, and v3 is natively
                // multilingual. `.spanish` is the first knob to try if
                // validation ever shows residual English drift.
                return try await manager.transcribe(samples, decoderState: &state, language: nil)
            }
            if let progressStream {
                group.addTask {
                    for try await fraction in progressStream {
                        onChannelFraction(fraction)
                    }
                    return nil
                }
            }
            group.addTask {
                while true {
                    if shouldYield() { throw TranscriptionError.preempted }
                    try await Task.sleep(for: yieldPollInterval)
                }
            }

            // The decode is the only child that ever yields a value; the
            // watcher only throws, and the progress consumer only ends.
            while let next = try await group.next() {
                if let next {
                    group.cancelAll()
                    return next
                }
            }
            throw TranscriptionError.preempted
        }
    }

    // MARK: Timings → segments (pure, table-testable)

    /// SentencePiece word-boundary marker: a token carrying it starts a new
    /// word, which is where a long segment is allowed to split.
    public static let wordBoundary = "▁"

    /// Turns one channel's token timings into transcript segments. Times are
    /// seconds, file-relative, already window-merged by FluidAudio — and the
    /// retained files begin at recording t=0, so they are absolute recording
    /// seconds with no offset math.
    ///
    /// Splits at every inter-token gap over `segmentGapSeconds`, at every
    /// `silenceStarts` instant a token crosses, and at the next word start
    /// once a running segment would pass `maxSegmentSeconds`. Empty-text
    /// segments are dropped; nothing else is filtered — Whisper's pathologies
    /// (noise transcriptions, boilerplate hallucinations, silence inventions)
    /// don't apply, and the dedup still runs afterwards.
    ///
    /// `silenceStarts` are the instants this channel's audio actually fell
    /// quiet (`EnergyEnvelope.silenceStarts`), in ascending order. They are
    /// what makes the cutter independent of the model's timing estimates,
    /// which measurably paper over real pauses; passing none leaves the pure
    /// token-timing behaviour, which is what the tables exercise.
    public static func segments(
        from timings: [TokenTiming],
        text: String,
        duration: TimeInterval,
        channel: AudioChannel,
        silenceStarts: [TimeInterval] = []
    ) -> [TranscriptSegment] {
        // Qualified because FluidAudio exports a `Speaker` of its own: the
        // diarizer's speaker profile. Echo never diarizes -- the speaker IS
        // the channel the audio arrived on -- so the ambiguity is worth
        // resolving loudly rather than by import order.
        let speaker: EchoCore.Speaker = channel == .microphone ? .me : .teammates

        guard !timings.isEmpty else {
            // Fallback, not the design: v3 batch always returns timings. If it
            // ever doesn't, one channel-spanning segment loses the timeline
            // but never the words.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            ErrorTrace.record(
                "Parakeet returned text with no token timings — emitting one channel-spanning segment",
                category: "TranscriptionPass",
                metadata: ["channel": channel.rawValue]
            )
            return [
                TranscriptSegment(
                    channel: channel,
                    speaker: speaker,
                    text: trimmed,
                    start: 0,
                    end: max(0, duration)
                )
            ]
        }

        // Rows are grouped as tokens first and turned into segments at the
        // end, because a row's leading punctuation has to be able to move to
        // the row before it — which is a decision about two rows at once.
        var groups: [[TokenTiming]] = []
        var current: [TokenTiming] = []

        func flush() {
            guard !current.isEmpty else { return }
            groups.append(current)
            current = []
        }

        var nextSilence = 0
        // The audio decides THAT a row ends; the tokenization decides WHERE.
        // A silence lands between two words, but the token that happens to
        // straddle it is often mid-word — the model emits sub-word pieces, so
        // cutting at the straddling token shears "break" into "bre" + "ak"
        // and "Nubank" into "Nuban" + "k". Latching the decision and spending
        // it at the next legal boundary keeps every cut the audio asked for
        // and puts none of them inside a word.
        var pendingCut = false
        for timing in timings {
            if let previous = current.last, let first = current.first {
                // Silences the emitted tokens already span can't split
                // anything: a model that stretched a token across a pause
                // leaves nowhere inside it to cut.
                while nextSilence < silenceStarts.count,
                    silenceStarts[nextSilence] <= previous.endTime
                {
                    nextSilence += 1
                }
                let crossesSilence =
                    nextSilence < silenceStarts.count
                    && silenceStarts[nextSilence] <= timing.startTime

                if crossesSilence || timing.startTime - previous.endTime > segmentGapSeconds {
                    pendingCut = true
                }
                if pendingCut, canStartSegment(timing.token) {
                    flush()
                    pendingCut = false
                } else if isWordStart(timing.token),
                    timing.endTime - first.startTime > maxSegmentSeconds
                {
                    flush()
                }
            }
            current.append(timing)
        }
        flush()

        // A row must never OPEN with punctuation. The model dates the period
        // that closes a sentence after the pause it was spoken before, so a
        // cut placed where the audio says lands in FRONT of it and the next
        // row reads ". Clásic te baja colección" — 30 % of rows on a measured
        // meeting. The mark belongs to the sentence it closes, so it moves
        // back to it.
        //
        // Only legal while the row keeps a word of its own. A lone "." IS the
        // whole row when the model stretched one across a long silence, and
        // welding that back would drag the previous row's span across the
        // silence — a lie to the dedup, whose evidence is levels measured over
        // a span. Those rows have no word to keep and are dropped below,
        // exactly as before.
        for index in groups.indices.dropFirst() {
            guard let firstWord = groups[index].firstIndex(where: { carriesAWord($0.token) }),
                firstWord > 0
            else { continue }
            groups[index - 1].append(contentsOf: groups[index].prefix(firstWord))
            groups[index].removeFirst(firstWord)
        }

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let text = joinedText(group)
            // A row with no letter and no digit in it says nothing — and
            // dropping one can't cost a word, because it has none. Silence
            // draws a lone "." out of the model, and cancelled bleed leaves
            // long stretches of exactly that: a measured 25 s of "You: ."
            // where the teammate's voice used to be.
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return TranscriptSegment(
                channel: channel,
                speaker: speaker,
                text: text,
                start: first.startTime,
                end: last.endTime
            )
        }
    }

    /// SentencePiece detokenization, identical to FluidAudio's own: pieces
    /// concatenate and the boundary marker becomes a space.
    private static func joinedText(_ timings: [TokenTiming]) -> String {
        timings
            .map { $0.token }
            .joined()
            .replacingOccurrences(of: wordBoundary, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isWordStart(_ token: String) -> Bool {
        token.hasPrefix(wordBoundary) || token.hasPrefix(" ")
    }

    /// Whether a row may begin at this token.
    ///
    /// A word start always may. So may a token carrying no letter and no
    /// digit: the detokenizer welds it to whatever precedes it, so opening a
    /// row there cannot strand a word fragment, and a row that turns out to
    /// be only punctuation is dropped on emit. That second case is what keeps
    /// the lone "." the model draws out of a long silence from being welded
    /// onto the last real word — which would hand the dedup a row whose span
    /// covers the whole pause.
    public static func canStartSegment(_ token: String) -> Bool {
        isWordStart(token) || !carriesAWord(token)
    }

    /// Whether a token holds any letter or digit — the same question the emit
    /// step asks of a whole row, asked of one piece.
    public static func carriesAWord(_ token: String) -> Bool {
        token.contains { $0.isLetter || $0.isNumber }
    }

    // MARK: Audio reading

    /// The whole retained channel as 16 kHz mono Float32. Read in bounded
    /// blocks so peak memory stays a block, not the file — the samples array
    /// itself is what the engine needs whole (~46 MB for a one-hour channel).
    public static func readSamples(at url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionError.unreadableAudio(error.localizedDescription)
        }
        guard file.processingFormat.commonFormat == .pcmFormatFloat32 else {
            throw TranscriptionError.unreadableAudio(
                "Unexpected decoded format for \(url.lastPathComponent)"
            )
        }

        let totalSamples = Int(file.length)
        guard totalSamples > 0 else { return [] }
        let blockSamples = Int(sampleRate * 60)

        var samples: [Float] = []
        samples.reserveCapacity(totalSamples)
        var position = 0
        while position < totalSamples {
            let count = min(blockSamples, totalSamples - position)
            samples += try read(file, window: position..<(position + count))
            position += count
        }
        return samples
    }

    private static func read(_ file: AVAudioFile, window: Range<Int>) throws -> [Float] {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(window.count)
            )
        else {
            throw TranscriptionError.unreadableAudio(
                "Couldn't allocate a \(window.count)-frame read buffer"
            )
        }
        do {
            file.framePosition = AVAudioFramePosition(window.lowerBound)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(window.count))
        } catch {
            throw TranscriptionError.unreadableAudio(error.localizedDescription)
        }
        guard let channelData = buffer.floatChannelData else {
            throw TranscriptionError.unreadableAudio("Decoded buffer exposes no Float channel data")
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}
