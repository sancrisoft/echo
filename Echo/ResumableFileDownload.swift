//
//  ResumableFileDownload.swift
//  Echo
//
//  Byte-honest, resumable transfer of ONE large file — the summary model's
//  weight file, which is 99.4% of the snapshot's bytes.
//
//  Why Echo owns this instead of handing the file to HubApi.snapshot like the
//  small configs: the Hub client reports per-file progress through a
//  task-scoped URLSessionDownloadDelegate handed to
//  `URLSession.download(for:delegate:)`, and on this OS that async API never
//  invokes the delegate at all. Measured against the real 3.27 GB file:
//
//      task-scoped delegate  → 285 MB in 45 s, 0 progress callbacks
//      session-scoped one    → 144 MB in 15 s, 0 progress callbacks
//      classic dataTask      → 193 MB in 10 s, 7080 progress callbacks
//
//  So injecting a session doesn't help; the async API is the problem. And the
//  consequence was fatal rather than cosmetic: the snapshot fraction stayed
//  frozen for the whole file, the stall watchdog (`ModelDownload`, 60 s of no
//  forward progress) cancelled a perfectly healthy transfer, and three
//  attempts later the user got "The download stalled and made no progress" —
//  deterministically, on every machine, for any file needing over a minute.
//  Upstream knows and has not fixed it (huggingface/swift-huggingface #50
//  "Fix Apple download progress reporting", #48, #52, #61).
//
//  Owning the transfer buys three things the Hub path cannot give:
//
//  * Honest progress — bytes, not files-finished. The Hub fraction counts file
//    COUNT (`Progress(totalUnitCount: filenames.count)`), so the 19 MB of
//    configs (0.6% of the data) filled 87.5% of the bar and the 3.27 GB of
//    weights was the last 12.5%.
//  * Working stall detection — the watchdog is fed real bytes, so a reported
//    stall is a stall.
//  * Real resume — `Range: bytes=N-` continues from the byte already on disk,
//    across retries, pauses AND app relaunches (verified end to end:
//    interrupted at 192,925,517 bytes, resumed with HTTP 206 from exactly
//    there). The Hub path staged into a URLSession temp file it never
//    surfaced, so every cancelled attempt threw its bytes away and leaked
//    ~500 MB into $TMPDIR — 5 GB had accumulated on the first machine that
//    hit this bug.
//
//  The resume arithmetic is a pure decision (`resumeDecision`) so it is
//  table-testable with no network and no multi-GB fixture; the URLSession
//  plumbing around it is deliberately thin.
//

import Foundation
import os

nonisolated enum ResumableFileDownload {

    private static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "ResumableFileDownload")

    /// Idle window before URLSession itself gives up on a request. Longer than
    /// the stall watchdog's 60 s on purpose: a silent connection should be
    /// cancelled-and-resumed by the watchdog (which continues from the bytes on
    /// disk) rather than surfacing a raw "request timed out" the user can only
    /// answer by starting over.
    private static let requestIdleTimeout: TimeInterval = 120

    // MARK: - The pure decision

    /// What a `.partial` already on disk means for the next attempt.
    enum Resume: Equatable {
        /// Every byte is already there; no request needed.
        case complete
        /// Ask the server for `byte…` and append.
        case resume(from: Int64)
        /// Nothing usable on disk (or more bytes than the file can hold, which
        /// only happens if a partial outlived the model it belonged to) — drop
        /// it and start over. Fail-safe direction: re-fetching costs bandwidth,
        /// while trusting a wrong partial would hand MLX a corrupt file.
        case restart
    }

    /// Pure so the arithmetic is table-testable. `expectedBytes` is nil when the
    /// server didn't report a size; a partial is then still resumable (the
    /// completeness claim just has to come from elsewhere).
    static func resumeDecision(partialBytes: Int64, expectedBytes: Int64?) -> Resume {
        guard partialBytes > 0 else { return .restart }
        guard let expectedBytes, expectedBytes > 0 else { return .resume(from: partialBytes) }
        if partialBytes == expectedBytes { return .complete }
        if partialBytes > expectedBytes { return .restart }
        return .resume(from: partialBytes)
    }

    // MARK: - Errors

    /// The server answered something the transfer can't use. Carries the code
    /// because the recovery differs (401/403 means the signed CDN URL expired
    /// and a fresh HEAD fixes it; 5xx is worth a retry).
    struct UnexpectedStatus: LocalizedError, Equatable {
        let code: Int
        var errorDescription: String? {
            "The model server answered with HTTP \(code)."
        }
    }

    /// The connection ended cleanly but short of the announced size — a
    /// truncated transfer. Never silently accepted: the partial stays on disk so
    /// the next attempt resumes, but this transfer did NOT complete.
    struct TruncatedTransfer: LocalizedError, Equatable {
        let bytesOnDisk: Int64
        let expectedBytes: Int64
        var errorDescription: String? {
            "The download ended early (\(bytesOnDisk) of \(expectedBytes) bytes). Retry to resume it."
        }
    }

    /// The server rejected our `Range` (HTTP 416). Internal, never surfaced: it
    /// means the partial on disk no longer lines up with the file being served,
    /// so `fetch` drops it and starts the transfer over — otherwise every
    /// attempt would re-offer the same bad offset and the download could never
    /// heal itself.
    private struct RangeRefused: Error {}

    // MARK: - The transfer

    /// Streams `url` into `partialURL`, resuming from whatever is already
    /// there, and reports the total byte count on disk as it grows.
    ///
    /// `partialURL` is Echo's own file, deliberately NOT a URLSession temp: it
    /// is what makes the transfer resumable across a pause, a stall retry and
    /// an app relaunch. The caller owns moving it into place once complete.
    ///
    /// Cancellation (a user pause, or the stall watchdog) stops the request and
    /// throws `CancellationError` with every received byte still on disk.
    ///
    /// - Returns: the byte count on disk when the transfer finished.
    @discardableResult
    static func fetch(
        from url: URL,
        expectedBytes: Int64?,
        into partialURL: URL,
        progress: @Sendable @escaping (Int64) -> Void
    ) async throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        switch resumeDecision(partialBytes: byteCount(at: partialURL), expectedBytes: expectedBytes) {
        case .complete:
            let bytes = byteCount(at: partialURL)
            progress(bytes)
            return bytes
        case .restart:
            try? fm.removeItem(at: partialURL)
        case .resume(let byte):
            log.info("Resuming transfer at byte \(byte, privacy: .public)")
        }

        do {
            try await transfer(from: url, into: partialURL, progress: progress)
        } catch is RangeRefused {
            // The offset on disk doesn't line up with the file being served.
            // Drop it and take the whole file — once: a second refusal is the
            // server's problem, not a stale partial, and surfaces as its status.
            log.warning("Server refused the resume range; restarting the transfer from zero")
            try? fm.removeItem(at: partialURL)
            progress(0)
            try await transfer(from: url, into: partialURL, progress: progress)
        }

        let bytes = byteCount(at: partialURL)
        if let expectedBytes, bytes != expectedBytes {
            throw TruncatedTransfer(bytesOnDisk: bytes, expectedBytes: expectedBytes)
        }
        return bytes
    }

    /// One request: opens (or re-opens) `partialURL`, asks for the bytes still
    /// missing, and streams them in. Returns when the connection finishes; the
    /// completeness verdict belongs to the caller.
    private static func transfer(
        from url: URL,
        into partialURL: URL,
        progress: @Sendable @escaping (Int64) -> Void
    ) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: partialURL.path) {
            fm.createFile(atPath: partialURL.path, contents: nil)
        }
        let offset = byteCount(at: partialURL)

        var request = URLRequest(url: url)
        request.timeoutInterval = requestIdleTimeout
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let sink = try Sink(partialURL: partialURL, offset: offset, progress: progress)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestIdleTimeout
        // A 3 GB transfer must not be cut off by a resource deadline, and it
        // must never be served from a cache: the bytes go to disk, not RAM.
        configuration.timeoutIntervalForResource = .infinity
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Session-scoped, which is the entire point of this file: this is the
        // delegate placement that actually receives byte callbacks.
        let session = URLSession(configuration: configuration, delegate: sink, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sink.onFinish = { result in continuation.resume(with: result) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Committed size of a file, or 0 when it isn't there.
    ///
    /// Read through FileManager rather than `URL.resourceValues`, which CACHES
    /// per URL value: asking the same URL twice returns the first answer, so the
    /// size of a file that is actively growing reads as whatever it was when the
    /// transfer started — silently breaking both the resume offset and the
    /// completeness check.
    static func byteCount(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - The session delegate

    /// Writes each received chunk straight to disk and reports the running byte
    /// count. Lock-guarded because URLSession delivers on its own worker queue
    /// while the caller reads the file size from another.
    private final class Sink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FileHandle
        private let progress: @Sendable (Int64) -> Void
        private var written: Int64
        private var failure: Error?
        private var finished = false

        /// Set before the task starts; called exactly once.
        var onFinish: ((Result<Void, Error>) -> Void)?

        init(
            partialURL: URL,
            offset: Int64,
            progress: @Sendable @escaping (Int64) -> Void
        ) throws {
            handle = try FileHandle(forWritingTo: partialURL)
            try handle.seekToEnd()
            self.progress = progress
            written = offset
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.allow)
                return
            }

            switch http.statusCode {
            case 206:
                // Range honoured: keep appending where we left off.
                completionHandler(.allow)
            case 200:
                // Some servers ignore Range and send the whole file. Appending
                // it to a partial would produce a plausible-looking, corrupt
                // file — rewind to zero and take the full copy instead.
                lock.lock()
                if written > 0 {
                    try? handle.truncate(atOffset: 0)
                    try? handle.seek(toOffset: 0)
                    written = 0
                }
                lock.unlock()
                completionHandler(.allow)
            case 416:
                // "Range not satisfiable": the bytes on disk don't line up with
                // the file being served. `fetch` drops the partial and starts
                // over — but only when we actually asked for a range; a 416 to
                // a range-less GET is just a broken server.
                lock.lock()
                failure = written > 0 ? RangeRefused() : UnexpectedStatus(code: 416)
                lock.unlock()
                completionHandler(.cancel)
            default:
                lock.lock()
                failure = UnexpectedStatus(code: http.statusCode)
                lock.unlock()
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            do {
                try handle.write(contentsOf: data)
                written += Int64(data.count)
            } catch {
                failure = failure ?? error
                lock.unlock()
                dataTask.cancel()
                return
            }
            let total = written
            lock.unlock()
            progress(total)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            try? handle.synchronize()
            try? handle.close()
            let recorded = failure
            lock.unlock()

            let finish = onFinish
            onFinish = nil

            // A status we refused (`recorded`) reads as a URLError.cancelled
            // here because WE cancelled the task — report the real reason, not
            // the cancellation it wore on the way out.
            if let recorded {
                finish?(.failure(recorded))
            } else if let error {
                finish?(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
            } else {
                finish?(.success(()))
            }
        }
    }
}
