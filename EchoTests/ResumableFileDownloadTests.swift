//
//  ResumableFileDownloadTests.swift
//  EchoTests
//
//  The transport that replaced HubApi.snapshot for the summary model's weight
//  file. Two layers:
//
//  * the pure resume arithmetic, table-tested;
//  * the real transfer, against a local HTTP server that speaks (or refuses to
//    speak) Range — the behaviors that decide whether a resumed multi-GB
//    download ends up correct or plausibly corrupt. A loopback server rather
//    than the Hub: these cases (server ignores Range, 416, short body, 5xx) are
//    exactly the ones a real download won't reproduce on demand.
//

import Foundation
import Network
import Testing
@testable import Echo

@Suite("Resumable file download")
struct ResumableFileDownloadTests {

    // MARK: - The pure decision

    @Test func nothingOnDiskStartsFromScratch() {
        #expect(ResumableFileDownload.resumeDecision(partialBytes: 0, expectedBytes: 100) == .restart)
    }

    @Test func partialBytesResumeFromWhereTheyStopped() {
        #expect(ResumableFileDownload.resumeDecision(partialBytes: 40, expectedBytes: 100) == .resume(from: 40))
    }

    @Test func everyByteOnDiskNeedsNoRequest() {
        #expect(ResumableFileDownload.resumeDecision(partialBytes: 100, expectedBytes: 100) == .complete)
    }

    /// More bytes than the file can hold means the partial outlived the file it
    /// belonged to (a model swap mid-download). Re-fetching costs bandwidth;
    /// trusting it would hand MLX a corrupt tensor file.
    @Test func oversizedPartialIsDiscarded() {
        #expect(ResumableFileDownload.resumeDecision(partialBytes: 140, expectedBytes: 100) == .restart)
    }

    @Test func unknownSizeStillResumes() {
        #expect(ResumableFileDownload.resumeDecision(partialBytes: 40, expectedBytes: nil) == .resume(from: 40))
        #expect(ResumableFileDownload.resumeDecision(partialBytes: 0, expectedBytes: nil) == .restart)
    }

    // MARK: - The real transfer

    @Test func freshTransferWritesEveryByte() async throws {
        let body = Self.payload(bytes: 64 * 1024)
        let server = try await LocalHTTPServer.start(body: body, behavior: .rangeAware)
        defer { server.stop() }
        let partial = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        let bytes = try await ResumableFileDownload.fetch(
            from: server.url,
            expectedBytes: Int64(body.count),
            into: partial,
            progress: { _ in }
        )

        #expect(bytes == Int64(body.count))
        #expect(try Data(contentsOf: partial) == body)
    }

    /// The regression this whole transport exists for: an interrupted transfer
    /// must continue from the byte on disk, not start over.
    @Test func interruptedTransferResumesFromTheByteOnDisk() async throws {
        let body = Self.payload(bytes: 64 * 1024)
        let server = try await LocalHTTPServer.start(body: body, behavior: .rangeAware)
        defer { server.stop() }
        let partial = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        // Stand in for a cancelled attempt: the first 20 KB already on disk.
        let head = body.prefix(20 * 1024)
        try Data(head).write(to: partial)

        let bytes = try await ResumableFileDownload.fetch(
            from: server.url,
            expectedBytes: Int64(body.count),
            into: partial,
            progress: { _ in }
        )

        #expect(bytes == Int64(body.count))
        #expect(try Data(contentsOf: partial) == body)          // stitched, not doubled
        #expect(server.observedRanges == ["bytes=\(head.count)-"])
        #expect(server.observedStatuses == [206])
    }

    /// Progress is reported as bytes on disk, monotonically, ending at the full
    /// size — the heartbeat the stall watchdog now runs on. A resumed transfer
    /// starts its reports ABOVE zero, which is what keeps the bar from
    /// snapping backwards on a retry.
    @Test func progressReportsBytesOnDiskAndNeverGoesBackwards() async throws {
        let body = Self.payload(bytes: 256 * 1024)
        let server = try await LocalHTTPServer.start(body: body, behavior: .rangeAware)
        defer { server.stop() }
        let partial = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: partial) }
        try Data(body.prefix(10 * 1024)).write(to: partial)

        let samples = Samples()
        _ = try await ResumableFileDownload.fetch(
            from: server.url,
            expectedBytes: Int64(body.count),
            into: partial,
            progress: { samples.record($0) }
        )

        let recorded = samples.values
        #expect(!recorded.isEmpty)
        #expect(recorded.first ?? 0 >= Int64(10 * 1024))
        #expect(recorded.last == Int64(body.count))
        #expect(recorded == recorded.sorted())
    }

    /// Some servers answer a Range request with the whole file. Appending that
    /// to a partial produces a plausible-looking, corrupt file — the transfer
    /// has to rewind instead.
    @Test func serverIgnoringRangeRestartsInsteadOfAppending() async throws {
        let body = Self.payload(bytes: 32 * 1024)
        let server = try await LocalHTTPServer.start(body: body, behavior: .ignoresRange)
        defer { server.stop() }
        let partial = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: partial) }
        try Data(body.prefix(8 * 1024)).write(to: partial)

        let bytes = try await ResumableFileDownload.fetch(
            from: server.url,
            expectedBytes: Int64(body.count),
            into: partial,
            progress: { _ in }
        )

        #expect(bytes == Int64(body.count))
        #expect(try Data(contentsOf: partial) == body)
    }

    /// A rejected range means the bytes on disk no longer line up with the file
    /// being served (a partial that outlived its model). The transfer has to heal
    /// itself by dropping them and taking the whole file — otherwise every
    /// attempt re-offers the same bad offset and the download can never finish.
    @Test func rejectedRangeHealsByRestartingFromZero() async throws {
        let body = Self.payload(bytes: 16 * 1024)
        let server = try await LocalHTTPServer.start(body: body, behavior: .notSatisfiableOnce)
        defer { server.stop() }
        let partial = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: partial) }
        // A partial that the server will refuse to resume.
        try Data(Self.payload(bytes: 4 * 1024)).write(to: partial)

        let bytes = try await ResumableFileDownload.fetch(
            from: server.url,
            expectedBytes: Int64(body.count),
            into: partial,
            progress: { _ in }
        )

        #expect(bytes == Int64(body.count))
        #expect(try Data(contentsOf: partial) == body)
        #expect(server.observedStatuses == [416, 200])
        // The retry asked for the whole file, not the offset that was refused.
        #expect(server.observedRanges == ["bytes=4096-"])
    }

    /// A 416 to a request that carried no Range is a broken server, not a stale
    /// partial: it surfaces instead of looping.
    @Test func rangelessRequestRejectedSurfacesItsStatus() async throws {
        let server = try await LocalHTTPServer.start(body: Data(), behavior: .notSatisfiable)
        defer { server.stop() }
        let partial = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        await #expect(throws: ResumableFileDownload.UnexpectedStatus(code: 416)) {
            try await ResumableFileDownload.fetch(
                from: server.url,
                expectedBytes: 1024,
                into: partial,
                progress: { _ in }
            )
        }
    }

    /// A complete-looking response that is short of the published size is a
    /// truncated transfer, never a finished one — the guard that stops a stale
    /// size or a proxy-mangled body from being blessed as the model.
    @Test func shortBodyIsReportedAsTruncated() async throws {
        let body = Self.payload(bytes: 8 * 1024)
        let server = try await LocalHTTPServer.start(body: body, behavior: .rangeAware)
        defer { server.stop() }
        let partial = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        await #expect(throws: ResumableFileDownload.TruncatedTransfer.self) {
            try await ResumableFileDownload.fetch(
                from: server.url,
                expectedBytes: Int64(body.count * 2),   // the repo claims twice as much
                into: partial,
                progress: { _ in }
            )
        }
        #expect(ResumableFileDownload.byteCount(at: partial) == Int64(body.count))
    }

    @Test func serverErrorSurfacesItsStatus() async throws {
        let server = try await LocalHTTPServer.start(body: Data(), behavior: .status(503))
        defer { server.stop() }
        let partial = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        await #expect(throws: ResumableFileDownload.UnexpectedStatus(code: 503)) {
            try await ResumableFileDownload.fetch(
                from: server.url,
                expectedBytes: 1024,
                into: partial,
                progress: { _ in }
            )
        }
    }

    /// A partial that already holds every byte short-circuits before any
    /// request — proven by pointing it at a port nothing is listening on.
    @Test func completePartialNeverTouchesTheNetwork() async throws {
        let partial = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: partial) }
        let body = Self.payload(bytes: 4 * 1024)
        try body.write(to: partial)

        let bytes = try await ResumableFileDownload.fetch(
            from: URL(string: "http://127.0.0.1:9/never-listening")!,
            expectedBytes: Int64(body.count),
            into: partial,
            progress: { _ in }
        )

        #expect(bytes == Int64(body.count))
    }

    /// Cancellation (a user pause, or the stall watchdog) must keep every
    /// received byte: that is what makes the resume above possible.
    @Test func cancellationKeepsTheBytesItAlreadyWrote() async throws {
        let body = Self.payload(bytes: 4 * 1024 * 1024)
        let server = try await LocalHTTPServer.start(body: body, behavior: .rangeAware, chunkSize: 16 * 1024, pauseBetweenChunks: 0.01)
        defer { server.stop() }
        let partial = Self.scratchFile()
        defer { try? FileManager.default.removeItem(at: partial) }

        let started = Signal()
        let task = Task {
            try await ResumableFileDownload.fetch(
                from: server.url,
                expectedBytes: Int64(body.count),
                into: partial,
                progress: { bytes in if bytes > 0 { started.signal() } }
            )
        }
        await started.wait()
        task.cancel()
        _ = try? await task.value

        let onDisk = ResumableFileDownload.byteCount(at: partial)
        #expect(onDisk > 0)
        #expect(onDisk < Int64(body.count))
    }

    // MARK: - Helpers

    /// Deterministic, incompressible-enough payload; the byte pattern makes a
    /// mis-stitched resume visible as a content mismatch.
    private static func payload(bytes count: Int) -> Data {
        var data = Data(capacity: count)
        for index in 0..<count {
            data.append(UInt8((index * 31 + index / 251) % 251))
        }
        return data
    }

    private static func scratchFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ResumableFileDownloadTests-\(UUID().uuidString).partial", directoryHint: .notDirectory)
    }

    /// Collects progress samples off URLSession's delegate queue.
    private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Int64] = []

        func record(_ value: Int64) {
            lock.lock()
            recorded.append(value)
            lock.unlock()
        }

        var values: [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    /// One-shot "it started" latch.
    private final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        func signal() {
            lock.lock()
            fired = true
            lock.unlock()
        }

        func wait() async {
            while true {
                lock.lock()
                let done = fired
                lock.unlock()
                if done { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }
}

/// Minimal loopback HTTP server with the Range behaviors a real CDN can throw
/// at a resumed download. Deliberately small: it parses a request line, reads
/// one `Range` header, and answers once per connection.
final class LocalHTTPServer: @unchecked Sendable {

    enum Behavior {
        /// Honours `Range` with a 206 and the requested suffix.
        case rangeAware
        /// Answers every request with the whole body and a 200.
        case ignoresRange
        /// Rejects the range with a 416, every time.
        case notSatisfiable
        /// Rejects the first request with a 416, then behaves normally — a
        /// partial that no longer lines up with the file being served.
        case notSatisfiableOnce
        /// Fails with the given status.
        case status(Int)
    }

    private let listener: NWListener
    private let body: Data
    private let behavior: Behavior
    private let chunkSize: Int
    private let pauseBetweenChunks: TimeInterval
    private let lock = NSLock()
    private var ranges: [String] = []
    private var statuses: [Int] = []

    /// Starts a server and returns once it is listening (the port is assigned
    /// with the `.ready` state). Async rather than a spin in `init`: blocking a
    /// cooperative thread starves the whole parallel test run.
    static func start(
        body: Data,
        behavior: Behavior,
        chunkSize: Int = 64 * 1024,
        pauseBetweenChunks: TimeInterval = 0
    ) async throws -> LocalHTTPServer {
        let server = try LocalHTTPServer(
            body: body,
            behavior: behavior,
            chunkSize: chunkSize,
            pauseBetweenChunks: pauseBetweenChunks
        )
        try await server.waitUntilReady()
        return server
    }

    private init(
        body: Data,
        behavior: Behavior,
        chunkSize: Int,
        pauseBetweenChunks: TimeInterval
    ) throws {
        self.body = body
        self.behavior = behavior
        self.chunkSize = chunkSize
        self.pauseBetweenChunks = pauseBetweenChunks
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
    }

    private func waitUntilReady() async throws {
        let gate = ReadyGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.arm(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(.success(()))
                case .failed(let error): gate.finish(.failure(error))
                case .cancelled: gate.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    /// Resumes the readiness continuation exactly once, from whichever state
    /// update arrives first.
    private final class ReadyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        func arm(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ result: Result<Void, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }

    var url: URL {
        URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)/file")!
    }

    /// `Range` header values the server was asked for, in order.
    var observedRanges: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ranges
    }

    /// Statuses the server answered with, in order.
    var observedStatuses: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return statuses
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            guard let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                self.receiveRequest(on: connection, buffer: accumulated)
                return
            }

            let header = String(decoding: accumulated[..<headerEnd.lowerBound], as: UTF8.self)
            self.respond(to: header, on: connection)
        }
    }

    private func respond(to header: String, on connection: NWConnection) {
        let requestedRange = header
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }

        if let requestedRange {
            lock.lock()
            ranges.append(requestedRange)
            lock.unlock()
        }

        let offset = requestedRange
            .flatMap { $0.split(separator: "=").last }
            .flatMap { $0.split(separator: "-").first }
            .flatMap { Int($0) }

        var status = 200
        var extraHeaders = ""
        var payload = body

        switch behavior {
        case .rangeAware:
            if let offset, offset > 0, offset < body.count {
                status = 206
                payload = body.suffix(from: offset)
                extraHeaders = "Content-Range: bytes \(offset)-\(body.count - 1)/\(body.count)\r\n"
            }
        case .ignoresRange:
            status = 200
        case .notSatisfiable:
            status = 416
            payload = Data("range not satisfiable".utf8)
        case .notSatisfiableOnce:
            lock.lock()
            let firstRequest = statuses.isEmpty
            lock.unlock()
            if firstRequest {
                status = 416
                payload = Data("range not satisfiable".utf8)
            } else if let offset, offset > 0, offset < body.count {
                status = 206
                payload = body.suffix(from: offset)
                extraHeaders = "Content-Range: bytes \(offset)-\(body.count - 1)/\(body.count)\r\n"
            }
        case .status(let code):
            status = code
            payload = Data("error".utf8)
        }

        lock.lock()
        statuses.append(status)
        lock.unlock()

        let head = """
        HTTP/1.1 \(status) \(Self.reason(status))\r
        Content-Length: \(payload.count)\r
        Accept-Ranges: bytes\r
        \(extraHeaders)Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        sendChunks(of: Data(payload), from: 0, on: connection)
    }

    /// Sends the body in chunks (optionally paced), so a test can cancel a
    /// transfer while it is genuinely mid-flight.
    private func sendChunks(of payload: Data, from index: Int, on connection: NWConnection) {
        guard index < payload.count else {
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        let end = min(index + chunkSize, payload.count)
        let chunk = payload[index..<end]
        connection.send(content: Data(chunk), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            if pauseBetweenChunks > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + pauseBetweenChunks) {
                    self.sendChunks(of: payload, from: end, on: connection)
                }
            } else {
                self.sendChunks(of: payload, from: end, on: connection)
            }
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 416: return "Range Not Satisfiable"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
