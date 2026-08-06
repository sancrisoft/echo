//
//  RetainedAudioWriter.swift
//  Echo
//
//  SP-005 S1 (ADR-013): writes each channel's pipeline-ingested audio — the
//  exact 16 kHz mono Float samples handed to `TranscriptionPipeline.ingest`,
//  mic post-AEC, system post-downmix — as a compressed per-channel file, so
//  the final re-transcription pass has the meeting's audio back after stop.
//
//  The retained timeline is faithful to the live clock: declared capture gaps
//  (`noteCaptureGap`) are written as equivalent silence, so every retained
//  sample's file position equals the recording-relative timestamp the live
//  pipeline assigned it. A packed file would time-shift every post-gap final
//  segment by the cumulative gap (ADR-013).
//
//  Subordinate to recording (SP-005 NFR): any write failure disables retention
//  for the session — logged, partial files removed, never a throw back into
//  the capture path. A truncated retention file must never feed a final pass,
//  or it would replace a fuller live transcript with less.
//

import AVFoundation
import Foundation
import os

actor RetainedAudioWriter {

    private static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "RetainedAudioWriter")

    /// AAC-LC mono 16 kHz at ~32 kbps: compressed speech-rate audio, bounded
    /// at roughly tens of MB per hour per channel (ADR-013 — never raw WAV).
    private static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: AudioConstants.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]

    private struct WriteFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Staging directory the per-channel files are written into. Created on
    /// the first write, so constructing a writer never touches the disk.
    private let directory: URL

    private var files: [AudioChannel: AVAudioFile] = [:]
    private var finished = false

    /// True once a write failed and retention was abandoned for this session.
    private(set) var isDisabled = false

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Ingest tee

    /// Appends one ingested batch for `channel`. Mirrors `pipeline.ingest`'s
    /// position in the timeline: call it with exactly the samples the pipeline
    /// receives, in the same order.
    func append(_ samples: [Float], to channel: AudioChannel) {
        guard !isDisabled, !finished, !samples.isEmpty else { return }
        do {
            try write(samples, to: file(for: channel))
        } catch {
            disable(reporting: error)
        }
    }

    /// Writes the silence equivalent of a declared capture gap so file
    /// position keeps mapping to the live clock (ADR-013). Validation mirrors
    /// `TranscriptionPipeline.noteCaptureGap`: only positive, finite gaps
    /// moved the live clock, so only those may widen the retained timeline.
    func noteGap(seconds: TimeInterval, on channel: AudioChannel) {
        guard !isDisabled, !finished else { return }
        guard seconds > 0, seconds.isFinite else { return }

        var remaining = Int((seconds * AudioConstants.sampleRate).rounded())
        // Fill in ≤1 s slabs so a long outage never allocates the whole gap.
        let slab = [Float](repeating: 0, count: min(remaining, Int(AudioConstants.sampleRate)))
        do {
            let file = try file(for: channel)
            while remaining > 0 {
                let count = min(remaining, slab.count)
                try write(count == slab.count ? slab : Array(slab.prefix(count)), to: file)
                remaining -= count
            }
        } catch {
            disable(reporting: error)
        }
    }

    // MARK: - Session end

    /// Closes the files and returns the staged per-channel URLs — empty when
    /// retention was disabled (partials were removed) or nothing was written.
    /// Later appends are ignored: a straggler ingest task landing after
    /// teardown must not touch a finalized file.
    func finish() -> [AudioChannel: URL] {
        finished = true
        let urls = files.mapValues(\.url)
        files.removeAll()   // releasing AVAudioFile finalizes the container
        return isDisabled ? [:] : urls
    }

    /// Drops the staged retention entirely (a session that was never
    /// persisted). Removes the staging directory and everything in it.
    func discard() {
        _ = finish()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Internals

    private func file(for channel: AudioChannel) throws -> AVAudioFile {
        if let file = files[channel] { return file }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(
            path: MeetingStore.retainedAudioFileName(for: channel),
            directoryHint: .notDirectory
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: Self.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        files[channel] = file
        return file
    }

    private func write(_ samples: [Float], to file: AVAudioFile) throws {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: AudioConstants.captureFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw WriteFailure(description: "Couldn't allocate a \(samples.count)-frame PCM buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    /// Retention is subordinate to recording: a failure abandons the session's
    /// retention (log + partial-file cleanup) and never propagates upward.
    private func disable(reporting error: Error) {
        guard !isDisabled else { return }
        isDisabled = true
        Self.log.error("Audio retention disabled for this session: \(String(describing: error), privacy: .public)")
        let staged = files.mapValues(\.url)
        files.removeAll()
        for url in staged.values {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
