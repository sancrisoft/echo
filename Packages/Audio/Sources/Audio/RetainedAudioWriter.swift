//
//  RetainedAudioWriter.swift
//  Audio
//
//  Writes each channel's pipeline-ingested audio — the exact 16 kHz mono
//  Float32 samples handed downstream, mic post-AEC, system post-downmix — as
//  a compressed per-channel file, so the transcription pass has the meeting's
//  audio back after stop.
//
//  The retained timeline is faithful to the live clock: declared capture gaps
//  (`noteGap`) are written as equivalent silence, so every retained sample's
//  file position equals the recording-relative timestamp the live pipeline
//  assigned it. A packed file would time-shift every post-gap segment by the
//  cumulative gap.
//
//  Retention is subordinate to recording: any write failure disables
//  retention for the session — logged, partial files removed, never a throw
//  back into the capture path. A truncated retention file must never feed a
//  pass, or it would replace a fuller transcript with less.
//
//  An `actor` because it owns files: appends arrive from both capture
//  channels at different cadences and must not interleave inside one
//  container.
//

import AVFoundation
import EchoCore
import Foundation
import os

public actor RetainedAudioWriter {

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "RetainedAudioWriter")

    /// AAC-LC mono 16 kHz at ~32 kbps: compressed speech-rate audio, bounded
    /// at roughly tens of MB per hour per channel — never raw WAV.
    /// Computed, not stored: a `[String: Any]` static is not `Sendable`, and
    /// it is built once per channel file.
    private static var fileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioConstants.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
    }

    private struct WriteFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// What actually reached each file, and what asked to and was turned
    /// away. The Others channel's retained audio comes out systematically
    /// shorter than the meeting (measured 4–8 % across real recordings,
    /// growing with load), and these two counters split the possible causes
    /// apart: audio that never arrived versus audio that arrived after the
    /// file was closed. The capture path counts what it handed over; the
    /// difference is the answer.
    public struct Accounting: Sendable {
        public var writtenFrames: [AudioChannel: Int] = [:]
        /// Appends refused because the file was already finalized — the
        /// straggler ingest tasks `finish()` documents dropping.
        public var rejectedFrames: [AudioChannel: Int] = [:]

        public init(writtenFrames: [AudioChannel: Int] = [:], rejectedFrames: [AudioChannel: Int] = [:]) {
            self.writtenFrames = writtenFrames
            self.rejectedFrames = rejectedFrames
        }
    }

    /// Staging directory the per-channel files are written into. Created on
    /// the first write, so constructing a writer never touches the disk.
    private let directory: URL

    /// What each channel's file is called. Injected because the audio name
    /// families belong to `Meetings`, which sits above this package in the
    /// dependency graph: Recording passes
    /// `MeetingStore.retainedAudioFileName`, and the one place that decides
    /// what a retained file is named stays the one place that classifies them
    /// later.
    private let fileName: @Sendable (AudioChannel) -> String

    private var files: [AudioChannel: AVAudioFile] = [:]
    private var finished = false
    private var accounting = Accounting()

    /// True once a write failed and retention was abandoned for this session.
    public private(set) var isDisabled = false

    public init(directory: URL, fileName: @escaping @Sendable (AudioChannel) -> String) {
        self.directory = directory
        self.fileName = fileName
    }

    // MARK: - Ingest tee

    /// Appends one ingested batch for `channel`. Mirrors the pipeline's
    /// position in the timeline: call it with exactly the samples the
    /// pipeline receives, in the same order.
    public func append(_ samples: [Float], to channel: AudioChannel) {
        guard !samples.isEmpty else { return }
        guard !isDisabled, !finished else {
            accounting.rejectedFrames[channel, default: 0] += samples.count
            return
        }
        do {
            try write(samples, to: file(for: channel), channel: channel)
        } catch {
            disable(reporting: error)
        }
    }

    /// Writes the silence equivalent of a declared capture gap so file
    /// position keeps mapping to the live clock. Only positive, finite gaps
    /// moved the live clock, so only those may widen the retained timeline.
    public func noteGap(seconds: TimeInterval, on channel: AudioChannel) {
        guard !isDisabled, !finished else { return }
        guard seconds > 0, seconds.isFinite else { return }

        var remaining = Int((seconds * AudioConstants.sampleRate).rounded())
        // Fill in <=1 s slabs so a long outage never allocates the whole gap.
        let slab = [Float](repeating: 0, count: min(remaining, Int(AudioConstants.sampleRate)))
        do {
            let file = try file(for: channel)
            while remaining > 0 {
                let count = min(remaining, slab.count)
                try write(count == slab.count ? slab : Array(slab.prefix(count)), to: file, channel: channel)
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
    public func finish() -> [AudioChannel: URL] {
        finished = true
        let urls = files.mapValues(\.url)
        files.removeAll()  // releasing AVAudioFile finalizes the container
        return isDisabled ? [:] : urls
    }

    /// Drops the staged retention entirely (a session that was never
    /// persisted). Removes the staging directory and everything in it.
    public func discard() {
        _ = finish()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Read after `finish()`, so the counts are final. Never clears: the stop
    /// path reads it once the files are closed and adopted.
    public func currentAccounting() -> Accounting { accounting }

    // MARK: - Internals

    private func file(for channel: AudioChannel) throws -> AVAudioFile {
        if let file = files[channel] { return file }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: fileName(channel), directoryHint: .notDirectory)
        let file = try AVAudioFile(
            forWriting: url,
            settings: Self.fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        files[channel] = file
        return file
    }

    private func write(_ samples: [Float], to file: AVAudioFile, channel: AudioChannel) throws {
        try write(samples, to: file)
        accounting.writtenFrames[channel, default: 0] += samples.count
    }

    private func write(_ samples: [Float], to file: AVAudioFile) throws {
        guard let format = AudioConstants.captureFormat,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let destination = buffer.floatChannelData?[0]
        else {
            throw WriteFailure(description: "Couldn't allocate a \(samples.count)-frame PCM buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            destination.update(from: base, count: samples.count)
        }
        try file.write(from: buffer)
    }

    /// Retention is subordinate to recording: a failure abandons the
    /// session's retention (log + partial-file cleanup) and never propagates
    /// upward.
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
