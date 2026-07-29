//
//  ErrorTraceLog.swift
//  Echo
//
//  Persistent error trace log. Every error surface in the app funnels through
//  `ErrorTrace.record(...)`, which does two things:
//
//    1. Mirrors the message to the unified log (os.Logger, same subsystem and
//       per-call-site category as before), so Console.app filtering keeps
//       working exactly as it always has.
//    2. Appends a structured `ErrorTraceRecord` to an NDJSON file under
//       ~/Library/Application Support/Echo/Logs (the single data root,
//       user decision 2026-07-13), one file per UTC day, so error history
//       survives relaunches and can be attached to a bug report.
//
//  Each record carries: a unique id, ISO-8601 timestamp, a per-launch session
//  id (groups records from the same run), category, human message, the
//  resolved error (Swift type, localizedDescription, NSError domain/code and
//  the underlying-error chain), source location (file:line, function), the
//  app version, and optional structured metadata.
//
//  Design constraints:
//    - Logging must never take the app down: `append` is best-effort and
//      swallows its own I/O failures (mirrored to the unified log only).
//    - Call sites never block: the record is built synchronously (accurate
//      timestamp/location) and persisted fire-and-forget through the actor,
//      which serializes file access. Records may land out of order across
//      concurrent tasks — `timestamp` is the authoritative ordering.
//    - Bounded disk: files older than `retentionDays` are pruned at launch
//      (EchoApp.init). Day boundaries and filenames use UTC, so rotation is
//      deterministic regardless of the machine's timezone.
//    - Local-first: records can contain file paths and error prose; they stay
//      on device like everything else under the Echo data root.
//

import Foundation
import os

/// One persisted error event — the unit of the on-disk trace log.
nonisolated struct ErrorTraceRecord: Codable, Sendable, Equatable {

    /// Unique id of this event.
    let id: UUID
    /// Moment the error was recorded (authoritative ordering key).
    let timestamp: Date
    /// One per process launch — groups records from the same run.
    let sessionID: UUID
    /// Same category string as the call site's os.Logger, for cross-reference.
    let category: String
    /// Human-readable description of what failed.
    let message: String

    /// Swift type name of the thrown error (e.g. "SummaryModelError").
    let errorType: String?
    /// `localizedDescription` of the thrown error.
    let errorDescription: String?
    /// NSError bridge: domain and code (Swift errors bridge to "Module.Type").
    let errorDomain: String?
    let errorCode: Int?
    /// `NSUnderlyingErrorKey` chain, outermost first, as "domain#code: description".
    let underlyingErrors: [String]?

    /// Optional structured context (ids, device names, status codes…).
    let metadata: [String: String]?

    /// Source location of the call site.
    let file: String
    let line: Int
    let function: String

    /// "CFBundleShortVersionString (CFBundleVersion)" of the running app.
    let appVersion: String?

    /// Resolves an optional thrown error into the record's flat fields.
    /// Deterministic inputs (`sessionID`, `timestamp`) are injectable for tests.
    static func make(
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

/// Serializes appends to the on-disk NDJSON trace files and owns rotation
/// and retention. Rooted at `EchoPaths.logsDirectory` in the app
/// (`ErrorTrace.shared`); injectable with a temp root in tests.
actor ErrorTraceLog {

    /// Days of error history kept on disk; older daily files are pruned.
    static let retentionDays = 14

    private static let fallbackLog = Logger(subsystem: "com.sancrisoft.Echo", category: "ErrorTraceLog")

    /// Filenames use the record's UTC calendar day: errors-2026-07-29.ndjson.
    private static let dayFormat = Date.ISO8601FormatStyle().year().month().day()

    private let directory: URL
    private let encoder: JSONEncoder

    init(directory: URL) {
        self.directory = directory
        let encoder = JSONEncoder()
        // Single-line JSON (NDJSON) with stable key order; timestamps keep
        // sub-second precision so same-second records still order correctly.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day()
                .timeZone(separator: .omitted).time(includingFractionalSeconds: true)))
        }
        self.encoder = encoder
    }

    /// Decoder matching the on-disk encoding, for readers and tests.
    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            return try Date(string, strategy: .iso8601.year().month().day()
                .timeZone(separator: .omitted).time(includingFractionalSeconds: true))
        }
        return decoder
    }

    /// The daily file a record with this timestamp belongs to.
    nonisolated func fileURL(for timestamp: Date) -> URL {
        directory.appending(
            path: "errors-\(timestamp.formatted(Self.dayFormat)).ndjson",
            directoryHint: .notDirectory
        )
    }

    /// Appends one record as a single NDJSON line. Best-effort by design:
    /// an I/O failure is mirrored to the unified log and swallowed — the
    /// trace log must never become an error source of its own.
    func append(_ record: ErrorTraceRecord) {
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
    func prune(now: Date = Date()) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }

        let cutoff = now.addingTimeInterval(-TimeInterval(Self.retentionDays) * 86_400)
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("errors-"), name.hasSuffix(".ndjson") else { continue }
            let day = String(name.dropFirst("errors-".count).dropLast(".ndjson".count))
            guard let date = try? Date(day, strategy: Self.dayFormat), date < cutoff else { continue }
            do {
                try FileManager.default.removeItem(at: entry)
            } catch {
                Self.fallbackLog.error("Pruning \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Call-site facade. `ErrorTrace.record("what failed", error: error,
/// category: "MeetingStore")` is the one line an error surface needs.
nonisolated enum ErrorTrace {

    /// One per process launch; ties together every record from this run.
    static let sessionID = UUID()

    /// The app-wide log, rooted at the single Echo data folder.
    static let shared = ErrorTraceLog(directory: EchoPaths.logsDirectory)

    private static let appVersion: String? = {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }()

    /// Records an error: mirrors it to the unified log under the given
    /// category and persists a structured trace record. Never blocks and
    /// never throws — safe on any code path, including teardown.
    static func record(
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
            appVersion: appVersion
        )

        var mirrored = message
        if let description = record.errorDescription { mirrored += ": \(description)" }
        if let metadata, !metadata.isEmpty {
            let context = metadata.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            mirrored += " [\(context)]"
        }
        Logger(subsystem: "com.sancrisoft.Echo", category: category)
            .error("\(mirrored, privacy: .public) (trace \(record.id.uuidString, privacy: .public))")

        Task(priority: .utility) { await shared.append(record) }
    }
}
