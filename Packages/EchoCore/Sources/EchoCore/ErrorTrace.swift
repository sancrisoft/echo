//
//  ErrorTrace.swift
//  EchoCore
//
//  The one way an error is logged. `ErrorTrace.record(...)` does two things:
//
//    1. Mirrors the message to the unified log (os.Logger, one subsystem, the
//       call site's category), so Console.app filtering works.
//    2. Appends a structured `ErrorTraceRecord` as one NDJSON line under
//       `Logs/` in the data root, one file per UTC day, so error history
//       survives relaunches and can be attached to a bug report.
//
//  Design constraints:
//    - Logging must never take the app down: `append` is best-effort and
//      swallows its own I/O failures (mirrored to the unified log only).
//    - Call sites never block: the record is built synchronously (accurate
//      timestamp and location) and persisted fire-and-forget through the
//      actor, which serializes file access. Records may land out of order
//      across concurrent tasks — `timestamp` is the authoritative ordering.
//    - Nothing is written until the composition root configures a log. Package
//      tests therefore never touch the real data folder: an unconfigured
//      `ErrorTrace` mirrors to the unified log and stops there.
//    - Bounded disk: files older than `retentionDays` are pruned at launch.
//      Day boundaries and filenames use UTC, so rotation is deterministic
//      regardless of the machine's timezone.
//    - Errors that carry user data (transcript text) never come here.
//

import Foundation
import Synchronization
import os

/// One persisted error event — the unit of the on-disk trace log.
public struct ErrorTraceRecord: Codable, Sendable, Equatable {

    /// Unique id of this event.
    public let id: UUID
    /// Moment the error was recorded (authoritative ordering key).
    public let timestamp: Date
    /// One per process launch — groups records from the same run.
    public let sessionID: UUID
    /// Same category string as the call site's os.Logger, for cross-reference.
    public let category: String
    /// Human-readable description of what failed.
    public let message: String

    /// Swift type name of the thrown error (e.g. "MeetingStoreError").
    public let errorType: String?
    /// `localizedDescription` of the thrown error.
    public let errorDescription: String?
    /// NSError bridge: domain and code (Swift errors bridge to "Module.Type").
    public let errorDomain: String?
    public let errorCode: Int?
    /// `NSUnderlyingErrorKey` chain, outermost first, as "domain#code: description".
    public let underlyingErrors: [String]?

    /// Optional structured context (ids, device names, status codes…).
    public let metadata: [String: String]?

    /// Source location of the call site.
    public let file: String
    public let line: Int
    public let function: String

    /// "CFBundleShortVersionString (CFBundleVersion)" of the running app.
    public let appVersion: String?

    /// Resolves an optional thrown error into the record's flat fields.
    /// Deterministic inputs (`sessionID`, `timestamp`) are injectable for tests.
    public static func make(
        message: String,
        error: (any Error)?,
        category: String,
        metadata: [String: String]? = nil,
        file: String,
        line: Int,
        function: String,
        sessionID: UUID,
        timestamp: Date = Date(),
        appVersion: String? = nil
    ) -> ErrorTraceRecord {
        var errorType: String?
        var errorDescription: String?
        var errorDomain: String?
        var errorCode: Int?
        var underlying: [String] = []

        if let error {
            errorType = String(describing: type(of: error))
            errorDescription = error.localizedDescription
            let nsError = error as NSError
            errorDomain = nsError.domain
            errorCode = nsError.code
            // Walk the underlying-error chain, depth-capped so a cyclic
            // userInfo can never hang the caller.
            var cursor = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            var depth = 0
            while let current = cursor, depth < 5 {
                underlying.append("\(current.domain)#\(current.code): \(current.localizedDescription)")
                cursor = current.userInfo[NSUnderlyingErrorKey] as? NSError
                depth += 1
            }
        }

        return ErrorTraceRecord(
            id: UUID(),
            timestamp: timestamp,
            sessionID: sessionID,
            category: category,
            message: message,
            errorType: errorType,
            errorDescription: errorDescription,
            errorDomain: errorDomain,
            errorCode: errorCode,
            underlyingErrors: underlying.isEmpty ? nil : underlying,
            metadata: metadata,
            file: file,
            line: line,
            function: function,
            appVersion: appVersion
        )
    }
}

/// Serializes appends to the on-disk NDJSON trace files and owns rotation and
/// retention. The app roots one at `DataRoot.logs`; tests inject a temporary
/// directory.
public actor ErrorTraceLog {

    /// Days of error history kept on disk; older daily files are pruned.
    public static let retentionDays = 14

    private static let fallbackLog = Logger(subsystem: AppIdentity.logSubsystem, category: "ErrorTraceLog")

    /// Filenames use the record's UTC calendar day: errors-2026-07-29.ndjson.
    private static let dayFormat = Date.ISO8601FormatStyle().year().month().day()

    private let directory: URL
    private let encoder: JSONEncoder

    public init(directory: URL) {
        self.directory = directory
        let encoder = JSONEncoder()
        // Single-line JSON (NDJSON) with stable key order; timestamps keep
        // sub-second precision so same-second records still order correctly.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(
                date.formatted(
                    .iso8601.year().month().day()
                        .timeZone(separator: .omitted).time(includingFractionalSeconds: true)))
        }
        self.encoder = encoder
    }

    /// Decoder matching the on-disk encoding, for readers and tests.
    public nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            return try Date(
                string,
                strategy: .iso8601.year().month().day()
                    .timeZone(separator: .omitted).time(includingFractionalSeconds: true))
        }
        return decoder
    }

    /// The daily file a record with this timestamp belongs to.
    public nonisolated func fileURL(for timestamp: Date) -> URL {
        directory.appending(
            path: "errors-\(timestamp.formatted(Self.dayFormat)).ndjson",
            directoryHint: .notDirectory
        )
    }

    /// Appends one record as a single NDJSON line. Best-effort by design: an
    /// I/O failure is mirrored to the unified log and swallowed — the trace log
    /// must never become an error source of its own.
    public func append(_ record: ErrorTraceRecord) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var data = try encoder.encode(record)
            data.append(0x0A)
            let url = fileURL(for: record.timestamp)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                // First record of the day creates the file.
                try data.write(to: url, options: .atomic)
            }
        } catch {
            Self.fallbackLog.error("Writing error trace failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes daily files older than `retentionDays`. The day is parsed from
    /// the filename (authoritative for what the file contains); files that
    /// don't match the naming scheme are left alone.
    public func prune(now: Date = Date()) {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
        else { return }

        let cutoff = now.addingTimeInterval(-TimeInterval(Self.retentionDays) * 86_400)
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("errors-"), name.hasSuffix(".ndjson") else { continue }
            let day = String(name.dropFirst("errors-".count).dropLast(".ndjson".count))
            guard let date = try? Date(day, strategy: Self.dayFormat), date < cutoff else { continue }
            do {
                try FileManager.default.removeItem(at: entry)
            } catch {
                Self.fallbackLog.error(
                    "Pruning \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Call-site facade. `ErrorTrace.record("what failed", error: error,
/// category: "MeetingStore")` is the one line an error surface needs.
public enum ErrorTrace {

    /// One per process launch; ties together every record from this run.
    public static let sessionID = UUID()

    /// The configured on-disk log, or `nil` until the composition root sets
    /// one. Package tests leave it unset and never write a file.
    private static let sink = Mutex<ErrorTraceLog?>(nil)

    /// Routes persisted records to `log`. Called once, by the app's
    /// composition root, after it has decided the data root.
    public static func configure(log: ErrorTraceLog?) {
        sink.withLock { $0 = log }
    }

    /// Records an error: mirrors it to the unified log under the given
    /// category and, when a log is configured, persists a structured trace
    /// record. Never blocks and never throws — safe on any code path,
    /// including teardown.
    public static func record(
        _ message: String,
        error: (any Error)? = nil,
        category: String,
        metadata: [String: String]? = nil,
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) {
        let record = ErrorTraceRecord.make(
            message: message,
            error: error,
            category: category,
            metadata: metadata,
            file: file,
            line: line,
            function: function,
            sessionID: sessionID,
            appVersion: AppIdentity.version.display
        )

        var mirrored = message
        if let description = record.errorDescription { mirrored += ": \(description)" }
        if let metadata, !metadata.isEmpty {
            let context = metadata.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            mirrored += " [\(context)]"
        }
        Logger(subsystem: AppIdentity.logSubsystem, category: category)
            .error("\(mirrored, privacy: .public) (trace \(record.id.uuidString, privacy: .public))")

        guard let log = sink.withLock({ $0 }) else { return }
        Task(priority: .utility) { await log.append(record) }
    }
}
