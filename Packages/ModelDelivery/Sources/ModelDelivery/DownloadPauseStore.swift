//
//  DownloadPauseStore.swift
//  ModelDelivery
//
//  The user's "pause this download" intent, persisted so neither an eager
//  launch download nor a prefetch silently resumes it — on this launch or the
//  next.
//
//  It exists as stored state, and not as something read back off a
//  `CancellationError`, because the two are indistinguishable at the catch
//  site: the watchdog's own cancel, a pause, and a torn connection all arrive
//  the same way. The intent is recorded BEFORE the in-flight transfer is
//  cancelled, so by the time a joined awaiter sees the cancellation,
//  `isPaused` already answers truthfully and a real failure can never be
//  mistaken for a pause.
//
//  Behind a protocol so tests use an in-memory fake; production is a
//  one-field JSON file in the single data root — never `UserDefaults`.
//

import EchoCore
import Foundation
import Synchronization

public protocol DownloadPauseStore: Sendable {
    var isPaused: Bool { get }
    func setPaused(_ paused: Bool)
}

/// The production pause store: a one-field JSON file under the data root.
///
/// Reads and writes are synchronous and cheap by design, not by omission. The
/// ordering guarantee above depends on `setPaused(true)` having completed
/// before the cancel on the very next line; an actor here would put a
/// suspension point between them and reopen the window where a pause reads as
/// a failure.
///
/// A missing or unreadable file reads as "not paused", so a first run — or a
/// deleted data folder — starts un-paused.
public final class FileDownloadPauseStore: DownloadPauseStore {

    /// Guards the file against concurrent readers and writers. A `Mutex`
    /// rather than an actor for the reason in the type's documentation: this
    /// has to stay synchronous.
    private let lock = Mutex(())
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Every field defaults so a missing key (an older file, or none) decodes.
    private struct Stored: Codable {
        var paused = false
    }

    public var isPaused: Bool {
        lock.withLock { _ in
            guard let data = try? Data(contentsOf: fileURL),
                let stored = try? JSONDecoder().decode(Stored.self, from: data)
            else { return false }
            return stored.paused
        }
    }

    public func setPaused(_ paused: Bool) {
        lock.withLock { _ in
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(Stored(paused: paused))
                try data.write(to: fileURL, options: .atomic)
            } catch {
                ErrorTrace.record(
                    "Writing the download pause state failed",
                    error: error,
                    category: "FileDownloadPauseStore"
                )
            }
        }
    }
}
