//
//  ResumableFileDownloadTests.swift
//  ModelDeliveryTests
//
//  The transport that replaced the Hub snapshot pass for the summary model's
//  weight file. Two layers:
//
//  * the pure resume arithmetic, table-tested;
//  * the real transfer, against a local HTTP server that speaks (or refuses to
//    speak) Range — the behaviors that decide whether a resumed multi-GB
//    download ends up correct or plausibly corrupt. A loopback server rather
//    than the real repo: these cases (server ignores Range, 416, short body,
//    5xx) are exactly the ones a real download won't reproduce on demand.
//
//  Nothing here waits on a clock. The server can be gated mid-body, so a test
//  that needs a transfer to be provably incomplete says so with a signal rather
//  than by pacing bytes against a stopwatch, and every partial lives in a
//  `TemporaryDirectory` that is removed with the test.
//

import EchoCoreTestSupport
import Foundation
import ModelDelivery
import Network
import Synchronization
import Testing

@Suite("Resumable file download")
struct ResumableFileDownloadTests {

    // MARK: - The pure decision

    @Test("nothing on disk starts from scratch")
    func nothingOnDiskStartsFromScratch() {
        #expect(ResumableFileDownload.resumeDecision(partialBytes: 0, expectedBytes: 100) == .restart)
    }

    @Test("partial bytes resume from where they stopped")
    func partialBytesResumeFromWhereTheyStopped() {
        #expect(ResumableFileDownload.resumeDecision(partialBytes: 40, expectedBytes: 100) == .resume(from: 40))
    }

    @Test("every byte on disk needs no request")
    func everyByteOnDiskNeedsNoRequest() {
        #expect(ResumableFileDownload.resumeDecision(partialBytes: 100, expectedBytes: 100) == .complete)
    }

    /// More bytes than the file can hold means the partial outlived the file it
    /// belonged to (a model swap mid-download). Re-fetching costs bandwidth;
    /// trusting it would hand the runtime a corrupt tensor file.
    @Test("an oversized partial is discarded")
    func oversizedPartialIsDiscarded() {
        #expect(ResumableFileDownload.resumeDecision(partialBytes: 140, expectedBytes: 100) == .restart)
    }

    @Test("an unknown size still resumes")
    func unknownSizeStillResumes() {
        #expect(ResumableFileDownload.resumeDecision(partialBytes: 40, expectedBytes: nil) == .resume(from: 40))
        #expect(ResumableFileDownload.resumeDecision(partialBytes: 0, expectedBytes: nil) == .restart)
    }

    // MARK: - The real transfer

    @Test("a fresh transfer writes every byte")
    func freshTransferWritesEveryByte() async throws {
        let body = Self.payload(bytes: 64 * 1024)
        let server = try await LocalHTTPServer.start(body: body, behavior: .rangeAware)
        defer { server.stop() }

        try await Self.withScratchFile { partial in
            let bytes = try await ResumableFileDownload.fetch(
                from: try server.url,
                expectedBytes: Int64(body.count),
                into: partial,
                progress: { _ in }
            )

            #expect(bytes == Int64(body.count))
            #expect(try Data(contentsOf: partial) == body)
        }
    }

    /// The regression this whole transport exists for: an interrupted transfer
    /// must continue from the byte on disk, not start over.
    @Test("an interrupted transfer resumes from the byte on disk")
    func interruptedTransferResumesFromTheByteOnDisk() async throws {
        let body = Self.payload(bytes: 64 * 1024)
        let server = try await LocalHTTPServer.start(body: body, behavior: .rangeAware)
        defer { server.stop() }

        try await Self.withScratchFile { partial in
            // Stand in for a cancelled attempt: the first 20 KB already on disk.
            let head = body.prefix(20 * 1024)
            try Data(head).write(to: partial)

            let bytes = try await ResumableFileDownload.fetch(
                from: try server.url,
                expectedBytes: Int64(body.count),
                into: partial,
                progress: { _ in }
            )

            #expect(bytes == Int64(body.count))
            #expect(try Data(contentsOf: partial) == body)  // stitched, not doubled
            #expect(server.observedRanges == ["bytes=\(head.count)-"])
            #expect(server.observedStatuses == [206])
        }
    }

    /// Progress is reported as bytes on disk, monotonically, ending at the full
    /// size — the heartbeat the stall watchdog runs on. A resumed transfer
    /// starts its reports ABOVE zero, which is what keeps the bar from snapping
    /// backwards on a retry.
    @Test("progress reports bytes on disk and never goes backwards")
    func progressReportsBytesOnDiskAndNeverGoesBackwards() async throws {
        let body = Self.payload(bytes: 256 * 1024)
        let server = try await LocalHTTPServer.start(body: body, behavior: .rangeAware)
        defer { server.stop() }

        try await Self.withScratchFile { partial in
            try Data(body.prefix(10 * 1024)).write(to: partial)

            let samples = Samples()
            _ = try await ResumableFileDownload.fetch(
                from: try server.url,
                expectedBytes: Int64(body.count),
                into: partial,
                progress: { samples.record($0) }
            )

            let recorded = samples.values
            #expect(!recorded.isEmpty)
            #expect((recorded.first ?? 0) >= Int64(10 * 1024))
            #expect(recorded.last == Int64(body.count))
            #expect(recorded == recorded.sorted())
        }
    }

    /// Some servers answer a Range request with the whole file. Appending that
    /// to a partial produces a plausible-looking, corrupt file — the transfer
    /// has to rewind instead.
    @Test("a server ignoring Range restarts instead of appending")
    func serverIgnoringRangeRestartsInsteadOfAppending() async throws {
        let body = Self.payload(bytes: 32 * 1024)
        let server = try await LocalHTTPServer.start(body: body, behavior: .ignoresRange)
        defer { server.stop() }

        try await Self.withScratchFile { partial in
            try Data(body.prefix(8 * 1024)).write(to: partial)

            let bytes = try await ResumableFileDownload.fetch(
                from: try server.url,
                expectedBytes: Int64(body.count),
                into: partial,
                progress: { _ in }
            )

            #expect(bytes == Int64(body.count))
            #expect(try Data(contentsOf: partial) == body)
        }
    }

    /// A rejected range means the bytes on disk no longer line up with the file
    /// being served (a partial that outlived its model). The transfer has to
    /// heal itself by dropping them and taking the whole file — otherwise every
    /// attempt re-offers the same bad offset and the download can never finish.
    @Test("a rejected range heals by restarting from zero")
    func rejectedRangeHealsByRestartingFromZero() async throws {
        let body = Self.payload(bytes: 16 * 1024)
        let server = try await LocalHTTPServer.start(body: body, behavior: .notSatisfiableOnce)
        defer { server.stop() }

        try await Self.withScratchFile { partial in
            // A partial that the server will refuse to resume.
            try Self.payload(bytes: 4 * 1024).write(to: partial)

            let bytes = try await ResumableFileDownload.fetch(
                from: try server.url,
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
    }

    /// A 416 to a request that carried no Range is a broken server, not a stale
    /// partial: it surfaces instead of looping.
    @Test("a rangeless request rejected surfaces its status")
    func rangelessRequestRejectedSurfacesItsStatus() async throws {
        let server = try await LocalHTTPServer.start(body: Data(), behavior: .notSatisfiable)
        defer { server.stop() }

        try await Self.withScratchFile { partial in
            let url = try server.url
            await #expect(throws: ModelDeliveryError.unexpectedStatus(code: 416)) {
                try await ResumableFileDownload.fetch(
                    from: url,
                    expectedBytes: 1024,
                    into: partial,
                    progress: { _ in }
                )
            }
        }
    }

    /// A complete-looking response that is short of the published size is a
    /// truncated transfer, never a finished one — the guard that stops a stale
    /// size or a proxy-mangled body from being blessed as the model.
    @Test("a short body is reported as truncated")
    func shortBodyIsReportedAsTruncated() async throws {
        let body = Self.payload(bytes: 8 * 1024)
        let server = try await LocalHTTPServer.start(body: body, behavior: .rangeAware)
        defer { server.stop() }

        try await Self.withScratchFile { partial in
            let url = try server.url
            let expected = Int64(body.count * 2)  // the repo claims twice as much
            await #expect(
                throws: ModelDeliveryError.truncatedTransfer(bytesOnDisk: Int64(body.count), expectedBytes: expected)
            ) {
                try await ResumableFileDownload.fetch(
                    from: url,
                    expectedBytes: expected,
                    into: partial,
                    progress: { _ in }
                )
            }
            #expect(ResumableFileDownload.byteCount(at: partial) == Int64(body.count))
        }
    }

    @Test("a server error surfaces its status")
    func serverErrorSurfacesItsStatus() async throws {
        let server = try await LocalHTTPServer.start(body: Data(), behavior: .status(503))
        defer { server.stop() }

        try await Self.withScratchFile { partial in
            let url = try server.url
            await #expect(throws: ModelDeliveryError.unexpectedStatus(code: 503)) {
                try await ResumableFileDownload.fetch(
                    from: url,
                    expectedBytes: 1024,
                    into: partial,
                    progress: { _ in }
                )
            }
        }
    }

    /// A partial that already holds every byte short-circuits before any
    /// request — proven by pointing it at a port nothing is listening on.
    @Test("a complete partial never touches the network")
    func completePartialNeverTouchesTheNetwork() async throws {
        try await Self.withScratchFile { partial in
            let body = Self.payload(bytes: 4 * 1024)
            try body.write(to: partial)
            let unreachable = try #require(URL(string: "http://127.0.0.1:9/never-listening"))

            let bytes = try await ResumableFileDownload.fetch(
                from: unreachable,
                expectedBytes: Int64(body.count),
                into: partial,
                progress: { _ in }
            )

            #expect(bytes == Int64(body.count))
        }
    }

    /// Cancellation (a user pause, or the stall watchdog) must keep every
    /// received byte: that is what makes the resume above possible.
    ///
    /// The server is gated rather than paced: it sends a slice of the body and
    /// then blocks, so the transfer is provably mid-body when the test cancels
    /// it — no clock decides how far it got.
    @Test("cancellation keeps the bytes it already wrote")
    func cancellationKeepsTheBytesItAlreadyWrote() async throws {
        let body = Self.payload(bytes: 4 * 1024 * 1024)
        let gate = ChunkGate()
        let server = try await LocalHTTPServer.start(
            body: body,
            behavior: .rangeAware,
            chunkSize: 16 * 1024,
            gate: gate,
            gateAfterBytes: 256 * 1024
        )
        defer { server.stop() }

        try await Self.withScratchFile { partial in
            let url = try server.url
            let started = Latch()
            let task = Task {
                try await ResumableFileDownload.fetch(
                    from: url,
                    expectedBytes: Int64(body.count),
                    into: partial,
                    progress: { bytes in
                        if bytes > 0 { started.signal() }
                    }
                )
            }

            // Resumes on the first byte written to disk; the gate guarantees the
            // server cannot have sent the rest of the body behind it.
            await started.wait()
            task.cancel()
            gate.open()
            _ = try? await task.value

            let onDisk = ResumableFileDownload.byteCount(at: partial)
            #expect(onDisk > 0)
            #expect(onDisk < Int64(body.count))
        }
    }

    // MARK: - Helpers

    /// Runs `body` against a partial file inside a fresh temp directory, then
    /// removes the directory. Never the real data root.
    private static func withScratchFile<T>(_ body: (URL) async throws -> T) async throws -> T {
        let temp = try TemporaryDirectory(prefix: "ResumableFileDownloadTests")
        defer { temp.remove() }
        return try await body(temp.path("weights.safetensors.partial"))
    }

    /// Deterministic, incompressible-enough payload; the byte pattern makes a
    /// mis-stitched resume visible as a content mismatch.
    private static func payload(bytes count: Int) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for index in 0..<count {
            bytes.append(UInt8((index * 31 + index / 251) % 251))
        }
        return Data(bytes)
    }
}

// MARK: - Test doubles

/// Collects progress samples off URLSession's delegate queue.
private final class Samples: Sendable {

    private let recorded = Mutex<[Int64]>([])

    func record(_ value: Int64) {
        recorded.withLock { $0.append(value) }
    }

    var values: [Int64] { recorded.withLock { $0 } }
}

/// A one-shot latch: `signal()` releases every `wait()`, whichever comes first.
/// Replaces the PoC's 5 ms poll loop — the waiter is resumed by the event
/// itself, so nothing depends on how long a poll takes to notice.
private final class Latch: Sendable {

    private struct State {
        var isSignalled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func signal() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock {
            guard !$0.isSignalled else { return [] }
            $0.isSignalled = true
            let pending = $0.waiters
            $0.waiters = []
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadySignalled: Bool = state.withLock {
                guard !$0.isSignalled else { return true }
                $0.waiters.append(continuation)
                return false
            }
            if alreadySignalled { continuation.resume() }
        }
    }
}

/// Parks the response body part-way through so a test can act on a transfer
/// that is provably incomplete. The alternative — pacing the server with a
/// per-chunk delay — makes the outcome a race between a test's clock and a
/// loopback socket.
private final class ChunkGate: Sendable {

    private struct State {
        var isOpen = false
        var parked: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    /// Called by the server: parks `resume` until `open()`, or runs it now if
    /// the gate is already open.
    func hold(_ resume: @escaping @Sendable () -> Void) {
        let isOpen: Bool = state.withLock {
            guard !$0.isOpen else { return true }
            $0.parked = resume
            return false
        }
        if isOpen { resume() }
    }

    /// Lets the rest of the body through.
    func open() {
        let parked: (@Sendable () -> Void)? = state.withLock {
            $0.isOpen = true
            let parked = $0.parked
            $0.parked = nil
            return parked
        }
        parked?()
    }
}

/// The port was not assigned — impossible after a successful `start()`, and a
/// thrown error rather than a force unwrap either way.
private struct ServerNotListening: Error {}

/// Minimal loopback HTTP server with the Range behaviors a real CDN can throw
/// at a resumed download. Deliberately small: it parses a request line, reads
/// one `Range` header, and answers once per connection. 127.0.0.1 only.
private final class LocalHTTPServer: Sendable {

    enum Behavior: Sendable {
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

    private struct Observed {
        var ranges: [String] = []
        var statuses: [Int] = []
    }

    private let listener: NWListener
    private let body: Data
    private let behavior: Behavior
    private let chunkSize: Int
    private let gate: ChunkGate?
    private let gateAfterBytes: Int
    private let observed = Mutex(Observed())
    private let hasParked = Mutex(false)

    /// Starts a server and returns once it is listening (the port is assigned
    /// with the `.ready` state). Async rather than a spin in `init`: blocking a
    /// cooperative thread starves the whole parallel test run.
    ///
    /// - Parameters:
    ///   - gate: when given, the body stops after `gateAfterBytes` until the
    ///     gate is opened.
    static func start(
        body: Data,
        behavior: Behavior,
        chunkSize: Int = 64 * 1024,
        gate: ChunkGate? = nil,
        gateAfterBytes: Int = .max
    ) async throws -> LocalHTTPServer {
        let server = try LocalHTTPServer(
            body: body,
            behavior: behavior,
            chunkSize: chunkSize,
            gate: gate,
            gateAfterBytes: gateAfterBytes
        )
        try await server.waitUntilReady()
        return server
    }

    private init(
        body: Data,
        behavior: Behavior,
        chunkSize: Int,
        gate: ChunkGate?,
        gateAfterBytes: Int
    ) throws {
        self.body = body
        self.behavior = behavior
        self.chunkSize = chunkSize
        self.gate = gate
        self.gateAfterBytes = gateAfterBytes
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
    }

    private func waitUntilReady() async throws {
        let gate = ReadyGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
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
    private final class ReadyGate: Sendable {

        private let continuation = Mutex<CheckedContinuation<Void, any Error>?>(nil)

        func arm(_ continuation: CheckedContinuation<Void, any Error>) {
            self.continuation.withLock { $0 = continuation }
        }

        func finish(_ result: Result<Void, any Error>) {
            let pending: CheckedContinuation<Void, any Error>? = continuation.withLock {
                let pending = $0
                $0 = nil
                return pending
            }
            pending?.resume(with: result)
        }
    }

    /// The address the server is listening on. Throws rather than force
    /// unwrapping; `start()` only returns once the port is assigned.
    var url: URL {
        get throws {
            guard let port = listener.port?.rawValue,
                let url = URL(string: "http://127.0.0.1:\(port)/file")
            else { throw ServerNotListening() }
            return url
        }
    }

    /// `Range` header values the server was asked for, in order.
    var observedRanges: [String] { observed.withLock { $0.ranges } }

    /// Statuses the server answered with, in order.
    var observedStatuses: [Int] { observed.withLock { $0.statuses } }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) {
            [weak self] data, _, isComplete, error in
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
        let requestedRange =
            header
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }

        if let requestedRange {
            observed.withLock { $0.ranges.append(requestedRange) }
        }

        let offset =
            requestedRange
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
            let firstRequest = observed.withLock { $0.statuses.isEmpty }
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

        observed.withLock { $0.statuses.append(status) }

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

    /// Sends the body in chunks, parking once at the gate when there is one, so
    /// a test can act on a transfer that is genuinely mid-flight.
    private func sendChunks(of payload: Data, from index: Int, on connection: NWConnection) {
        guard index < payload.count else {
            connection.send(
                content: nil,
                isComplete: true,
                completion: .contentProcessed { _ in
                    connection.cancel()
                }
            )
            return
        }
        if let gate, index >= gateAfterBytes, claimGate() {
            gate.hold { [weak self] in
                self?.sendChunks(of: payload, from: index, on: connection)
            }
            return
        }
        let end = min(index + chunkSize, payload.count)
        let chunk = payload[index..<end]
        connection.send(
            content: Data(chunk),
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                // The client hung up (a cancelled transfer): stop rather than
                // pushing the rest of the body at a dead socket.
                guard error == nil else {
                    connection.cancel()
                    return
                }
                self.sendChunks(of: payload, from: end, on: connection)
            }
        )
    }

    /// True the first time only: the body parks at the gate once, and runs
    /// straight through it afterwards.
    private func claimGate() -> Bool {
        hasParked.withLock {
            guard !$0 else { return false }
            $0 = true
            return true
        }
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
