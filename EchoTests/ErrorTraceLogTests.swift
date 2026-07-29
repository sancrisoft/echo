//
//  ErrorTraceLogTests.swift
//  EchoTests
//
//  Exercises the persistent error trace log against a temp directory per
//  test: record resolution (error fields, underlying-error chain), NDJSON
//  shape (one physical line per record, decodable round-trip), daily file
//  rotation, and retention pruning. No audio involved — pure persistence.
//

import Foundation
import Testing
@testable import Echo

@Suite("ErrorTraceLog")
struct ErrorTraceLogTests {

    // MARK: - Helpers

    /// Runs `body` against a log rooted at a fresh temp directory, then removes
    /// it. The directory does not exist up front — the log must create it.
    private func withTempLog<T>(_ body: (ErrorTraceLog, URL) async throws -> T) async rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ErrorTraceLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(ErrorTraceLog(directory: root), root)
    }

    private func makeRecord(
        message: String = "Something failed",
        error: (any Error)? = nil,
        metadata: [String: String]? = nil,
        timestamp: Date = Date(timeIntervalSince1970: 1_785_000_000)
    ) -> ErrorTraceRecord {
        ErrorTraceRecord.make(
            message: message,
            error: error,
            category: "Tests",
            metadata: metadata,
            file: "EchoTests/ErrorTraceLogTests.swift",
            line: 42,
            function: "test()",
            sessionID: UUID(),
            timestamp: timestamp,
            appVersion: "1.0 (1)"
        )
    }

    private func lines(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    // MARK: - Record resolution

    @Test("Resolves NSError domain, code and the underlying chain")
    func resolvesNSErrorFields() {
        let leaf = NSError(domain: "LeafDomain", code: 7)
        let underlying = NSError(
            domain: "MidDomain", code: 3,
            userInfo: [NSUnderlyingErrorKey: leaf]
        )
        let outer = NSError(
            domain: "OuterDomain", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "outer failed",
                NSUnderlyingErrorKey: underlying,
            ]
        )

        let record = makeRecord(error: outer)

        #expect(record.errorDomain == "OuterDomain")
        #expect(record.errorCode == 1)
        #expect(record.errorDescription == "outer failed")
        #expect(record.underlyingErrors?.count == 2)
        #expect(record.underlyingErrors?.first?.hasPrefix("MidDomain#3") == true)
        #expect(record.underlyingErrors?.last?.hasPrefix("LeafDomain#7") == true)
    }

    @Test("Resolves a Swift error's type name; no-error records stay flat")
    func resolvesSwiftErrorAndNil() {
        struct FakeError: Error {}

        let withError = makeRecord(error: FakeError())
        #expect(withError.errorType == "FakeError")
        #expect(withError.errorDomain != nil)

        let withoutError = makeRecord(error: nil)
        #expect(withoutError.errorType == nil)
        #expect(withoutError.errorDescription == nil)
        #expect(withoutError.errorDomain == nil)
        #expect(withoutError.errorCode == nil)
        #expect(withoutError.underlyingErrors == nil)
    }

    @Test("Every record gets a unique id")
    func uniqueIDs() {
        #expect(makeRecord().id != makeRecord().id)
    }

    // MARK: - NDJSON shape

    @Test("Append writes one decodable NDJSON line per record")
    func appendRoundTrips() async throws {
        try await withTempLog { log, _ in
            let record = makeRecord(
                error: NSError(domain: "D", code: 9),
                metadata: ["meetingID": "abc"]
            )
            await log.append(record)
            await log.append(makeRecord(message: "Second failure"))

            let lines = try lines(of: log.fileURL(for: record.timestamp))
            #expect(lines.count == 2)

            let decoder = ErrorTraceLog.makeDecoder()
            let decoded = try decoder.decode(ErrorTraceRecord.self, from: Data(lines[0].utf8))
            #expect(decoded == record)
        }
    }

    @Test("A multi-line message still lands as a single physical line")
    func multiLineMessageStaysOneLine() async throws {
        try await withTempLog { log, _ in
            let record = makeRecord(message: "line one\nline two")
            await log.append(record)

            let lines = try lines(of: log.fileURL(for: record.timestamp))
            #expect(lines.count == 1)

            let decoded = try ErrorTraceLog.makeDecoder()
                .decode(ErrorTraceRecord.self, from: Data(lines[0].utf8))
            #expect(decoded.message == "line one\nline two")
        }
    }

    // MARK: - Rotation

    @Test("Records partition into one file per UTC day")
    func dailyRotation() async throws {
        try await withTempLog { log, root in
            let dayOne = Date(timeIntervalSince1970: 1_785_000_000)
            let dayTwo = dayOne.addingTimeInterval(86_400)
            await log.append(makeRecord(timestamp: dayOne))
            await log.append(makeRecord(timestamp: dayTwo))

            let files = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            #expect(files.count == 2)
            #expect(files.allSatisfy { $0.hasPrefix("errors-") && $0.hasSuffix(".ndjson") })
            #expect(log.fileURL(for: dayOne).lastPathComponent != log.fileURL(for: dayTwo).lastPathComponent)
        }
    }

    // MARK: - Retention

    @Test("Prune drops files past retention and keeps recent + foreign files")
    func pruneRespectsRetention() async throws {
        try await withTempLog { log, root in
            let now = Date(timeIntervalSince1970: 1_785_000_000)
            let oldDay = now.addingTimeInterval(-TimeInterval(ErrorTraceLog.retentionDays + 2) * 86_400)
            let recentDay = now.addingTimeInterval(-86_400)

            await log.append(makeRecord(timestamp: oldDay))
            await log.append(makeRecord(timestamp: recentDay))
            // A file that doesn't match the naming scheme must be left alone.
            let foreign = root.appending(path: "notes.txt", directoryHint: .notDirectory)
            try Data("keep me".utf8).write(to: foreign)

            await log.prune(now: now)

            let survivors = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            #expect(!survivors.contains(log.fileURL(for: oldDay).lastPathComponent))
            #expect(survivors.contains(log.fileURL(for: recentDay).lastPathComponent))
            #expect(survivors.contains("notes.txt"))
        }
    }

    @Test("Prune on a missing directory is a no-op")
    func pruneMissingDirectory() async throws {
        await withTempLog { log, _ in
            await log.prune()   // directory never created — must not trap
        }
    }
}
