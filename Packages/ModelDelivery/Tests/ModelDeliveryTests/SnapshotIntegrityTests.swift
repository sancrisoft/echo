//
//  SnapshotIntegrityTests.swift
//  ModelDeliveryTests
//
//  The gate a weight file passes through on its way into the snapshot. For an
//  LFS file the Hub's etag IS the sha256 of the content, so the commit step is
//  a real end-to-end integrity check on a resumed, range-stitched transfer —
//  the one place a silently corrupt multi-GB tensor file could otherwise enter
//  the snapshot and be loaded as weights. The PoC had no tests here at all;
//  this suite is new.
//
//  Also pinned: the Hub `.metadata` sidecar written beside a committed file.
//  Without it the Hub's own passes treat a file this package transferred as
//  foreign — its download pass re-fetches gigabytes it already has, and its
//  offline pass rejects the repo directory outright.
//
//  Nothing here downloads anything. `HubApi.FileMetadata` is public but its
//  memberwise initializer is internal to swift-transformers, and production
//  must not grow a seam just to make a test constructible, so the metadata is
//  read back from a HEAD against a loopback server answering with the Hub's own
//  headers — 127.0.0.1, a kernel-assigned port, torn down with the call.
//

import CryptoKit
import EchoCoreTestSupport
import Foundation
import Hub
import Network
import Synchronization
import Testing

@testable import ModelDelivery

@Suite("Snapshot integrity")
struct SnapshotIntegrityTests {

    private static let spec = SnapshotSpec(
        repoID: "test-org/test-model",
        weightGlobs: ["model*.safetensors"],
        configGlobs: ["*.json"],
        manifestFileName: "summary-model-manifest.json",
        partialDirectoryName: "summary-model-download"
    )

    private static let weightName = "model.safetensors"

    /// The chunk `sha256Hex` streams the file in.
    private static let chunkBytes = 4 * 1024 * 1024

    private func makeDownloader(modelsRoot: URL) -> SnapshotDownloader {
        SnapshotDownloader(modelsRoot: modelsRoot, spec: Self.spec)
    }

    private func sidecarURL(in downloader: SnapshotDownloader, for name: String) -> URL {
        downloader.snapshotDirectory
            .appending(path: ".cache", directoryHint: .isDirectory)
            .appending(path: "huggingface", directoryHint: .isDirectory)
            .appending(path: "download", directoryHint: .isDirectory)
            .appending(path: name + ".metadata", directoryHint: .notDirectory)
    }

    // MARK: - The digest

    /// The hash the integrity check rests on, against CryptoKit over the same
    /// bytes. The sizes straddle the 4 MB chunk boundary in both directions and
    /// land exactly on it, because a streamed hash that mis-handles the last
    /// short read is indistinguishable from a correct one on small inputs — and
    /// the real input is a multi-GB tensor file.
    @Test(
        "the streamed digest matches CryptoKit across the chunk boundary",
        arguments: [
            0,
            1,
            chunkBytes - 1,
            chunkBytes,
            chunkBytes + 1_234,
        ]
    )
    func streamedDigestMatchesCryptoKit(byteCount: Int) throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotIntegrityTests")
        defer { temp.remove() }
        let bytes = Self.payload(bytes: byteCount)
        let file = temp.path("weights.safetensors")
        try bytes.write(to: file)

        #expect(try SnapshotDownloader.sha256Hex(of: file) == Self.digest(of: bytes))
    }

    // MARK: - Which etags are digests

    /// Which etags the integrity check is willing to compare against. A repo's
    /// LFS files carry a sha256; its plain files carry a git object id, which
    /// is 40 hex characters and must not be mistaken for one.
    @Test(
        "a 64-character hex string is a digest and nothing else is",
        arguments: [
            (String(repeating: "a", count: 64), true),
            ("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", true),
            // Uppercase passes the gate: `isHexDigit` is case-insensitive.
            // `sha256Hex` only ever emits lowercase, so an uppercase etag would
            // then fail the comparison and read as corruption rather than as a
            // format the check cannot use.
            (String(repeating: "A", count: 64), true),
            (String(repeating: "a", count: 63), false),
            (String(repeating: "a", count: 65), false),
            ("", false),
            (String(repeating: "z", count: 64), false),
            // A git object id — the etag a non-LFS file carries.
            ("356a192b7913b04c54574d18c28d46e6395428ab", false),
        ] as [(String, Bool)]
    )
    func onlyA64CharacterHexStringIsADigest(value: String, expected: Bool) {
        #expect(SnapshotDownloader.isSHA256(value) == expected)
    }

    // MARK: - Committing a verified file

    /// The happy path, end to end: the transfer's bytes hash to the published
    /// etag, the partial moves into the snapshot, and the Hub sidecar lands
    /// where the Hub looks for it, in the Hub's own three-line shape.
    @Test("a file matching its etag moves into the snapshot and gets its Hub sidecar")
    func matchingFileIsCommittedWithItsSidecar() async throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotIntegrityTests")
        defer { temp.remove() }
        let downloader = makeDownloader(modelsRoot: temp.path("Models"))
        let bytes = Self.payload(bytes: 8_192)
        let partial = temp.path("model.safetensors.partial")
        try bytes.write(to: partial)
        let commitHash = "9d2c1f0ab3e4567890abcdef1234567890abcdef"
        let metadata = try await Self.metadata(
            commitHash: commitHash,
            etag: Self.digest(of: bytes),
            downloadBase: temp.url
        )
        let destination = downloader.snapshotDirectory.appending(path: Self.weightName)

        try downloader.commitWeightFile(
            at: partial,
            to: destination,
            name: Self.weightName,
            metadata: metadata
        )

        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(try Data(contentsOf: destination) == bytes)

        let sidecar = sidecarURL(in: downloader, for: Self.weightName)
        let contents = try String(contentsOf: sidecar, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        try #require(lines.count >= 3)
        #expect(lines[0] == commitHash)
        #expect(lines[1] == Self.digest(of: bytes))
        // The third line is a timestamp. Only that it is a number is asserted —
        // its value is the wall clock, which no test may pin.
        #expect(Double(lines[2]) != nil)
    }

    /// A re-run over a snapshot whose file is present but wrong (a truncated
    /// commit from a killed process) replaces it rather than failing on the
    /// existing file.
    @Test("committing over an already present file replaces it")
    func commitReplacesAnAlreadyPresentFile() async throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotIntegrityTests")
        defer { temp.remove() }
        let downloader = makeDownloader(modelsRoot: temp.path("Models"))
        let destination = downloader.snapshotDirectory.appending(path: Self.weightName)
        try FileManager.default.createDirectory(
            at: downloader.snapshotDirectory,
            withIntermediateDirectories: true
        )
        try Data("stale truncated bytes".utf8).write(to: destination)

        let bytes = Self.payload(bytes: 4_096)
        let partial = temp.path("model.safetensors.partial")
        try bytes.write(to: partial)
        let metadata = try await Self.metadata(
            commitHash: "abc123",
            etag: Self.digest(of: bytes),
            downloadBase: temp.url
        )

        try downloader.commitWeightFile(
            at: partial,
            to: destination,
            name: Self.weightName,
            metadata: metadata
        )

        #expect(try Data(contentsOf: destination) == bytes)
    }

    // MARK: - Rejecting a corrupt file

    /// The reason the check exists. A partial whose bytes do not hash to the
    /// published digest never becomes a weight file: the commit throws, the bad
    /// partial is deleted so the next attempt cannot resume onto it, and the
    /// snapshot directory holds nothing at the destination — so completeness
    /// stays honestly false and the download retries.
    @Test("a file that does not match its digest is rejected and its partial deleted")
    func mismatchedDigestIsRejectedAndThePartialDeleted() async throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotIntegrityTests")
        defer { temp.remove() }
        let downloader = makeDownloader(modelsRoot: temp.path("Models"))
        let partial = temp.path("model.safetensors.partial")
        try Self.payload(bytes: 4_096).write(to: partial)
        // A well-formed digest that is simply not this file's.
        let metadata = try await Self.metadata(
            commitHash: "abc123",
            etag: String(repeating: "a", count: 64),
            downloadBase: temp.url
        )
        let destination = downloader.snapshotDirectory.appending(path: Self.weightName)

        #expect(throws: ModelDeliveryError.integrityCheckFailed(file: Self.weightName)) {
            try downloader.commitWeightFile(
                at: partial,
                to: destination,
                name: Self.weightName,
                metadata: metadata
            )
        }

        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: sidecarURL(in: downloader, for: Self.weightName).path))
    }

    /// An etag that is not a digest is not a failed digest. A non-LFS file's
    /// git object id carries no content hash to compare, so the check is
    /// skipped and the file commits — refusing it would strand a snapshot on a
    /// file the Hub itself considers fine.
    @Test("an etag that is not a digest skips the check and commits")
    func nonDigestEtagSkipsTheCheck() async throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotIntegrityTests")
        defer { temp.remove() }
        let downloader = makeDownloader(modelsRoot: temp.path("Models"))
        let bytes = Self.payload(bytes: 2_048)
        let partial = temp.path("model.safetensors.partial")
        try bytes.write(to: partial)
        // 40 hex characters: a git object id, and provably not these bytes.
        let metadata = try await Self.metadata(
            commitHash: "abc123",
            etag: "356a192b7913b04c54574d18c28d46e6395428ab",
            downloadBase: temp.url
        )
        let destination = downloader.snapshotDirectory.appending(path: Self.weightName)

        try downloader.commitWeightFile(
            at: partial,
            to: destination,
            name: Self.weightName,
            metadata: metadata
        )

        #expect(try Data(contentsOf: destination) == bytes)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    // MARK: - The sidecar's preconditions

    /// A sidecar the Hub cannot use is worse than none: it would make the Hub's
    /// resume bookkeeping trust a record with nothing to match on. Without a
    /// commit hash there is nothing to write, and nothing at all is created —
    /// not even the `.cache` tree.
    @Test("no sidecar is written without a commit hash")
    func noSidecarWithoutACommitHash() async throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotIntegrityTests")
        defer { temp.remove() }
        let downloader = makeDownloader(modelsRoot: temp.path("Models"))
        let metadata = try await Self.metadata(
            commitHash: nil,
            etag: String(repeating: "a", count: 64),
            downloadBase: temp.url
        )

        try downloader.writeHubSidecar(for: Self.weightName, metadata: metadata)

        #expect(!FileManager.default.fileExists(atPath: sidecarURL(in: downloader, for: Self.weightName).path))
        #expect(!FileManager.default.fileExists(atPath: downloader.snapshotDirectory.path))
    }

    @Test("no sidecar is written without an etag")
    func noSidecarWithoutAnEtag() async throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotIntegrityTests")
        defer { temp.remove() }
        let downloader = makeDownloader(modelsRoot: temp.path("Models"))
        let metadata = try await Self.metadata(commitHash: "abc123", etag: nil, downloadBase: temp.url)

        try downloader.writeHubSidecar(for: Self.weightName, metadata: metadata)

        #expect(!FileManager.default.fileExists(atPath: sidecarURL(in: downloader, for: Self.weightName).path))
        #expect(!FileManager.default.fileExists(atPath: downloader.snapshotDirectory.path))
    }

    // MARK: - Helpers

    /// Deterministic bytes; the pattern makes a chunk-boundary slip show up as
    /// a digest mismatch rather than a coincidental match.
    private static func payload(bytes count: Int) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for index in 0..<count {
            bytes.append(UInt8((index * 31 + index / 251) % 251))
        }
        return Data(bytes)
    }

    /// The expected digest, computed independently of the code under test.
    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A real `HubApi.FileMetadata`, built the only way this test module can:
    /// read back from a HEAD against a loopback server that answers with the
    /// Hub's own headers. See this file's header for why.
    private static func metadata(
        commitHash: String?,
        etag: String?,
        downloadBase: URL
    ) async throws -> HubApi.FileMetadata {
        var headers: [String: String] = [:]
        if let commitHash { headers["X-Repo-Commit"] = commitHash }
        if let etag { headers["X-Linked-Etag"] = etag }
        let server = try await LocalMetadataServer.start(headers: headers)
        defer { server.stop() }
        return try await HubApi(downloadBase: downloadBase, cache: nil)
            .getFileMetadata(url: server.url)
    }
}

// MARK: - Test doubles

/// A loopback server that answers one HEAD with the headers it was given. Just
/// enough of the Hub's metadata endpoint to make a `HubApi.FileMetadata` real,
/// and no more: no body, no ranges, no redirects.
private final class LocalMetadataServer: Sendable {

    private let listener: NWListener
    private let headers: [String: String]

    struct NotListening: Error {}

    /// Starts a server and returns once it is listening, which is when the
    /// kernel has assigned the port. Async rather than a spin in `init`:
    /// blocking a cooperative thread starves the whole parallel test run.
    static func start(headers: [String: String]) async throws -> LocalMetadataServer {
        let server = try LocalMetadataServer(headers: headers)
        try await server.waitUntilReady()
        return server
    }

    private init(headers: [String: String]) throws {
        self.headers = headers
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
    }

    /// The address the server is listening on. Throws rather than force
    /// unwrapping; `start()` only returns once the port is assigned.
    var url: URL {
        get throws {
            guard let port = listener.port?.rawValue,
                let url = URL(string: "http://127.0.0.1:\(port)/model.safetensors")
            else { throw NotListening() }
            return url
        }
    }

    func stop() {
        listener.cancel()
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

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        receive(on: connection, accumulated: Data())
    }

    /// Reads until the request headers are complete, then answers. The body of
    /// a HEAD request is never sent, so the blank-line terminator is the whole
    /// parse.
    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            guard error == nil else {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                respond(on: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                receive(on: connection, accumulated: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection) {
        var response = "HTTP/1.1 200 OK\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            response += "\(name): \(value)\r\n"
        }
        response += "X-Linked-Size: 4096\r\n"
        response += "Content-Length: 0\r\n"
        response += "Connection: close\r\n\r\n"
        connection.send(
            content: Data(response.utf8),
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}
