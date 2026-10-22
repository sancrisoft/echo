//
//  ResumableFileDownload.swift
//  ModelDelivery
//
//  Byte-honest, resumable transfer of ONE large file — the summary model's
//  weight file, which is 99.4% of the snapshot's bytes.
//
//  Why this package owns the transfer instead of handing the file to the Hub
//  snapshot pass like the small configs: the Hub client reports per-file
//  progress through a task-scoped `URLSessionDownloadDelegate` handed to
//  `URLSession.download(for:delegate:)`, and on this OS that async API never
//  invokes the delegate at all. Measured against the real 3.27 GB file:
//
//      task-scoped delegate  → 285 MB in 45 s, 0 progress callbacks
//      session-scoped one    → 144 MB in 15 s, 0 progress callbacks
//      classic dataTask      → 193 MB in 10 s, 7080 progress callbacks
//
//  So injecting a session does not help; the async API is the problem. And the
//  consequence was fatal rather than cosmetic: the snapshot fraction stayed
//  frozen for the whole file, the stall watchdog (`DownloadRetry`, 60 s of no
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

import EchoCore
import Foundation
import Synchronization
import os

public enum ResumableFileDownload {

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "ResumableFileDownload")

    /// Idle window before URLSession itself gives up on a request. Longer than
    /// the stall watchdog's 60 s on purpose: a silent connection should be
    /// cancelled-and-resumed by the watchdog (which continues from the bytes on
    /// disk) rather than surfacing a raw "request timed out" the user can only
    /// answer by starting over.
    private static let requestIdleTimeout: TimeInterval = 120

    // MARK: - The pure decision

    /// What a partial already on disk means for the next attempt.
    public enum Resume: Equatable, Sendable {
        /// Every byte is already there; no request needed.
        case complete
        /// Ask the server for `byte…` and append.
        case resume(from: Int64)
        /// Nothing usable on disk (or more bytes than the file can hold, which
        /// only happens if a partial outlived the model it belonged to) — drop
        /// it and start over. Fail-safe direction: re-fetching costs bandwidth,
        /// while trusting a wrong partial would hand the runtime a corrupt file.
        case restart
    }

    /// Pure so the arithmetic is table-testable. `expectedBytes` is nil when the
    /// server did not report a size; a partial is then still resumable (the
    /// completeness claim just has to come from elsewhere).
    public static func resumeDecision(partialBytes: Int64, expectedBytes: Int64?) -> Resume {
        guard partialBytes > 0 else { return .restart }
        guard let expectedBytes, expectedBytes > 0 else { return .resume(from: partialBytes) }
        if partialBytes == expectedBytes { return .complete }
        if partialBytes > expectedBytes { return .restart }
        return .resume(from: partialBytes)
    }

    // MARK: - The transfer

    /// Streams `url` into `partialURL`, resuming from whatever is already
    /// there, and reports the total byte count on disk as it grows.
    ///
    /// `partialURL` is this package's own file, deliberately NOT a URLSession
    /// temp: it is what makes the transfer resumable across a pause, a stall
    /// retry and an app relaunch. The caller owns moving it into place once
    /// complete.
    ///
    /// Cancellation (a user pause, or the stall watchdog) stops the request and
    /// throws `CancellationError` with every received byte still on disk.
    ///
    /// - Returns: the byte count on disk when the transfer finished.
    @discardableResult
    public static func fetch(
        from url: URL,
        expectedBytes: Int64?,
        into partialURL: URL,
        progress: @Sendable @escaping (Int64) -> Void
    ) async throws -> Int64 {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: partialURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        switch resumeDecision(partialBytes: byteCount(at: partialURL), expectedBytes: expectedBytes) {
        case .complete:
            let bytes = byteCount(at: partialURL)
            progress(bytes)
            return bytes
        case .restart:
            try? fileManager.removeItem(at: partialURL)
        case .resume(let byte):
            log.info("Resuming transfer at byte \(byte, privacy: .public)")
        }

        do {
            try await transfer(from: url, into: partialURL, progress: progress)
        } catch is RangeRefused {
            // The offset on disk does not line up with the file being served.
            // Drop it and take the whole file — once: a second refusal is the
            // server's problem, not a stale partial, and surfaces as its status.
            log.warning("Server refused the resume range; restarting the transfer from zero")
            try? fileManager.removeItem(at: partialURL)
            progress(0)
            try await transfer(from: url, into: partialURL, progress: progress)
        }

        let bytes = byteCount(at: partialURL)
        if let expectedBytes, bytes != expectedBytes {
            throw ModelDeliveryError.truncatedTransfer(bytesOnDisk: bytes, expectedBytes: expectedBytes)
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
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: partialURL.path) {
            fileManager.createFile(atPath: partialURL.path, contents: nil)
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
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                sink.setFinish { result in continuation.resume(with: result) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Committed size of a file, or 0 when it is not there.
    ///
    /// Read through FileManager rather than `URL.resourceValues`, which CACHES
    /// per URL value: asking the same URL twice returns the first answer, so the
    /// size of a file that is actively growing reads as whatever it was when the
    /// transfer started — silently breaking both the resume offset and the
    /// completeness check.
    public static func byteCount(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// The server rejected our `Range` (HTTP 416). Internal, never surfaced: it
/// means the partial on disk no longer lines up with the file being served, so
/// `fetch` drops it and starts the transfer over — otherwise every attempt
/// would re-offer the same bad offset and the download could never heal itself.
struct RangeRefused: Error {}

/// Writes each received chunk straight to disk and reports the running byte
/// count.
///
/// Every mutable field lives behind one `Mutex` because URLSession delivers on
/// its own worker queue while the caller reads from another. `onFinish` is in
/// there too: it is taken and cleared in the same critical section that sets
/// `finished`, which is what makes the continuation resume exactly once.
private final class Sink: NSObject, URLSessionDataDelegate, Sendable {

    private struct State {
        var handle: FileHandle
        var written: Int64
        var failure: (any Error)?
        var finished = false
        var onFinish: (@Sendable (Result<Void, any Error>) -> Void)?
        /// Set when the task finished before anyone was waiting, so the
        /// result is not lost between `setFinish` and the delegate callback.
        var result: Result<Void, any Error>?
    }

    private let state: Mutex<State>
    private let progress: @Sendable (Int64) -> Void

    init(
        partialURL: URL,
        offset: Int64,
        progress: @Sendable @escaping (Int64) -> Void
    ) throws {
        let handle = try FileHandle(forWritingTo: partialURL)
        try handle.seekToEnd()
        self.state = Mutex(State(handle: handle, written: offset))
        self.progress = progress
    }

    /// Set before the task starts; the closure is called exactly once. Call
    /// this at most once per sink — a second waiter would be stored in a slot
    /// the delegate has already emptied and would never be called. `transfer`
    /// builds a fresh sink for every request, which is what upholds that.
    ///
    /// A task cancelled before it is resumed — the caller was already
    /// cancelled when the transfer began — can complete before this runs. The
    /// delegate then parks its result here rather than dropping it, because a
    /// dropped result strands the continuation and hangs the transfer forever
    /// with nothing to diagnose.
    func setFinish(_ finish: @escaping @Sendable (Result<Void, any Error>) -> Void) {
        let pending: Result<Void, any Error>? = state.withLock {
            guard let result = $0.result else {
                $0.onFinish = finish
                return nil
            }
            $0.result = nil
            return result
        }
        if let pending { finish(pending) }
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
            state.withLock {
                if $0.written > 0 {
                    try? $0.handle.truncate(atOffset: 0)
                    try? $0.handle.seek(toOffset: 0)
                    $0.written = 0
                }
            }
            completionHandler(.allow)
        case 416:
            // "Range not satisfiable": the bytes on disk do not line up with
            // the file being served. `fetch` drops the partial and starts
            // over — but only when we actually asked for a range; a 416 to
            // a range-less GET is just a broken server.
            state.withLock {
                $0.failure = $0.written > 0 ? RangeRefused() : ModelDeliveryError.unexpectedStatus(code: 416)
            }
            completionHandler(.cancel)
        default:
            state.withLock { $0.failure = ModelDeliveryError.unexpectedStatus(code: http.statusCode) }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let total: Int64? = state.withLock {
            do {
                try $0.handle.write(contentsOf: data)
                $0.written += Int64(data.count)
                return $0.written
            } catch {
                $0.failure = $0.failure ?? error
                return nil
            }
        }
        guard let total else {
            dataTask.cancel()
            return
        }
        progress(total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // Deciding the result, taking the waiter and parking an unclaimed
        // result all happen in ONE critical section. Split across two, a
        // `setFinish` interleaving between them would see no parked result,
        // store its closure into a slot nobody reads again, and strand the
        // continuation.
        let delivery: (finish: @Sendable (Result<Void, any Error>) -> Void, result: Result<Void, any Error>)? =
            state.withLock { state in
                guard !state.finished else { return nil }
                state.finished = true
                try? state.handle.synchronize()
                try? state.handle.close()

                // A status we refused (`failure`) reads as a URLError.cancelled
                // here because WE cancelled the task — report the real reason,
                // not the cancellation it wore on the way out.
                let result: Result<Void, any Error>
                if let recorded = state.failure {
                    result = .failure(recorded)
                } else if let error {
                    result = .failure((error as? URLError)?.code == .cancelled ? CancellationError() : error)
                } else {
                    result = .success(())
                }

                guard let onFinish = state.onFinish else {
                    // Nobody is waiting yet; `setFinish` delivers it.
                    state.result = result
                    return nil
                }
                state.onFinish = nil
                return (onFinish, result)
            }
        // Called outside the lock: the continuation resume must not run under it.
        if let delivery { delivery.finish(delivery.result) }
    }
}
