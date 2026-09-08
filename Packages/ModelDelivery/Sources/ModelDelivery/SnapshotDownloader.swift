//
//  SnapshotDownloader.swift
//  ModelDelivery
//
//  Fetches one model's snapshot with two transports and reports ONE
//  byte-weighted fraction across both: the small configs ride the Hub snapshot
//  pass, the weight files ride this package's own resumable transfer
//  (`ResumableFileDownload`), and `SnapshotDownloadTally` reconciles them.
//
//  The order of the guarantees here is deliberate, and each has cost a
//  shipped release once:
//   1. Refuse to start below the disk floor, rather than discover it several
//      GB in.
//   2. Re-resolve repo metadata on every attempt: the `location` a HEAD
//      returns for an LFS file is a signed CDN URL that expires, so a stall
//      retry an hour into a slow download needs a fresh one. The HEADs cost
//      one request per file against a transfer measured in gigabytes.
//   3. Verify a committed weight file against the etag before it enters the
//      snapshot — for LFS files the Hub's etag IS the sha256 of the content.
//   4. Never record a manifest for a transfer that did not finish, and verify
//      the file set is really on disk before recording it.
//
//  Progress leaves as a phase and a fraction, never as a sentence: the words a
//  user reads are the UI's to choose, and an engine package that hardcoded
//  them could not be reused by a second model.
//

import CryptoKit
import EchoCore
import Foundation
import Hub
import Synchronization
import os

/// What the download is doing right now. The fraction that travels beside it
/// is always the byte-weighted one.
public enum SnapshotDownloadPhase: Equatable, Sendable {
    /// Bytes are moving.
    case downloading
    /// The watchdog cancelled a silent transfer and is starting `attempt`.
    case retryingAfterStall(attempt: Int)
}

/// Downloads one model's snapshot into a models root, and answers whether it
/// is already there.
public struct SnapshotDownloader: Sendable {

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "SnapshotDownloader")

    /// The download base: `<data root>/Models`. Everything this type reads or
    /// writes is under it.
    public let modelsRoot: URL

    /// Which repo, which globs, which bookkeeping file names.
    public let spec: SnapshotSpec

    /// Free bytes required before the first request.
    public let diskFloor: Int64

    public init(modelsRoot: URL, spec: SnapshotSpec, diskFloor: Int64 = DiskSpace.defaultFloor) {
        self.modelsRoot = modelsRoot
        self.spec = spec
        self.diskFloor = diskFloor
    }

    // MARK: - Paths

    /// The Hub client every path here shares. `cache: nil` is mandatory, not a
    /// preference: the default `HubCache.default` stores request caches
    /// OUTSIDE the app's data folder, and everything this app writes must stay
    /// under its one root. `hfToken` stays nil so auth resolves from the
    /// environment (unset here) rather than a stale token.
    var hub: HubApi {
        HubApi(downloadBase: modelsRoot, cache: nil)
    }

    /// `<models root>/models/<org>/<repo>` — the Hub's snapshot layout.
    public var snapshotDirectory: URL {
        hub.localRepoLocation(HubApi.Repo(id: spec.repoID))
    }

    /// Where the completeness manifest lives: beside the models tree, NOT
    /// inside the Hub-managed snapshot directory. The Hub's offline-mode
    /// snapshot pass validates every repo file matching the download globs and
    /// fails on one without a `.metadata` sidecar, so a foreign JSON planted in
    /// the repo directory would poison offline resume. One file, scoped to the
    /// model by the record's own modelID: a model swap makes the old record
    /// read as absent, and the new model's first completed download supersedes
    /// it.
    public var manifestFileURL: URL {
        modelsRoot.appending(path: spec.manifestFileName, directoryHint: .notDirectory)
    }

    /// Directory holding in-flight `.partial` files, consulted by the "is there
    /// something resumable" check. Beside the models tree for the same reason
    /// as the manifest.
    public var partialDownloadDirectory: URL {
        modelsRoot.appending(path: spec.partialDirectoryName, directoryHint: .isDirectory)
    }

    private func partialFileURL(for name: String) -> URL {
        partialDownloadDirectory.appending(path: name + ".partial", directoryHint: .notDirectory)
    }

    // MARK: - What is already on disk

    /// Whether a complete snapshot is already on disk: manifest AND
    /// files-on-disk. Layout-agnostic (no hardcoded file list, no sharding
    /// index parse) and offline — this app never needs the network to know it
    /// already has the model. A snapshot predating the manifest mechanism
    /// reads incomplete until the next online pass no-ops per committed file
    /// and records one.
    public func snapshotExists() -> Bool {
        SnapshotManifest.snapshotComplete(
            forModelID: spec.repoID,
            in: snapshotDirectory,
            manifestAt: manifestFileURL
        )
    }

    /// Bytes an interrupted download already put on disk (complete files, the
    /// Hub's resumable `*.incomplete` staging, and this package's own
    /// `.partial` transfers), or nil when nothing is there.
    ///
    /// Consumed only as a boolean "is there a resumable partial" signal — the
    /// number itself must never reach the UI: it sums staging alongside
    /// committed files and can exceed the committed total, so it cannot back a
    /// percentage or an "X of Y" readout. A resumed download continues from
    /// whatever is on disk regardless.
    public func partialDownloadBytes() -> Int64? {
        guard !snapshotExists() else { return nil }
        let total = Self.byteCount(under: snapshotDirectory) + Self.byteCount(under: partialDownloadDirectory)
        return total > 0 ? total : nil
    }

    /// Recursive byte sum of the regular files under `directory`; 0 when it
    /// does not exist.
    private static func byteCount(under directory: URL) -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            )
        else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - The download

    /// Runs the snapshot download to completion and records the manifest that
    /// makes `snapshotExists()` true.
    ///
    /// Cancellation (a user pause, or the stall watchdog) leaves every received
    /// byte on disk and throws `CancellationError` — never a failure, so a
    /// caller can tell a pause from a broken download.
    public func download(progress: @Sendable @escaping (SnapshotDownloadPhase, Double) -> Void) async throws {
        try DiskSpace.check(at: modelsRoot, floor: diskFloor)
        progress(.downloading, 0)

        // The bar must not snap back to zero on a stall retry — remember the
        // fraction the download actually reached (callbacks arrive on
        // URLSession worker threads, hence the lock).
        let reached = HighWaterFraction()
        do {
            // Stall watchdog and retry: a download that stops moving BYTES is
            // cancelled and re-run, resuming from the bytes already on disk.
            // The heartbeat is byte-derived on purpose — fed the Hub client's
            // own fraction, this watchdog killed every healthy multi-GB
            // transfer at the 60 s mark (see `ResumableFileDownload`).
            try await DownloadRetry.withStallRetry(
                onRetry: { attempt in
                    Self.log.warning("Snapshot download stalled; retrying (attempt \(attempt, privacy: .public))")
                    progress(.retryingAfterStall(attempt: attempt), reached.value)
                },
                operation: { noteProgress in
                    try await transferSnapshot { fraction in
                        noteProgress(fraction)
                        reached.update(fraction)
                        progress(.downloading, fraction)
                    }
                }
            )
        } catch is CancellationError {
            // A pause (or the watchdog's own cancel) is not a failure: the
            // partial stays on disk and the resume continues from it. Leaving
            // through the cancellation path keeps a caller's joiners able to
            // tell a pause from a broken download.
            throw CancellationError()
        } catch let error as ModelDeliveryError {
            throw error
        } catch {
            throw ModelDeliveryError.downloadFailed(error.localizedDescription)
        }

        // A pause cancels the download task, and the Hub snapshot then RETURNS
        // early between files instead of throwing — never record a manifest for
        // a transfer that did not finish; completeness stays honestly
        // incomplete and the resume re-enters here.
        if Task.isCancelled { return }

        try await recordManifest()
    }

    /// Records what "complete" means for this snapshot: the file set the
    /// downloader itself resolves. `getFilenames(matching:)` is the exact
    /// resolution the snapshot pass ran on, so no repo layout fact lives in
    /// code. Resolved against the repo (not a directory listing) on purpose: a
    /// listing measures what arrived, not what the load needs, and would bless
    /// a snapshot whose stale staging metadata let a file go missing.
    /// Verify-then-write keeps a recorded manifest meaning "a download
    /// genuinely completed here".
    private func recordManifest() async throws {
        do {
            let resolved = try await hub.getFilenames(
                from: HubApi.Repo(id: spec.repoID),
                matching: spec.downloadGlobs
            )
            let manifest = SnapshotManifest(modelID: spec.repoID, files: resolved.sorted())
            guard manifest.allFilesCommitted(in: snapshotDirectory) else {
                throw ModelDeliveryError.snapshotVerificationFailed
            }
            try manifest.write(to: manifestFileURL)
            // The transfers were moved into the snapshot, so what is left here
            // is at most an empty directory — or a `.partial` for a file this
            // snapshot no longer contains (a model swap mid-download). Either
            // way it is dead weight the moment completeness is recorded.
            try? FileManager.default.removeItem(at: partialDownloadDirectory)
        } catch let error as ModelDeliveryError {
            // Already one of ours (the verification failure above): rethrow it
            // with its case intact. The PoC could only ever surface this as a
            // message, because the type it threw was private to the manager;
            // here a caller can key a retry affordance on the case itself.
            throw error
        } catch {
            // Fail-safe direction: no manifest was recorded, so the snapshot
            // keeps reading incomplete and a retry re-verifies cheaply (the Hub
            // skips files already on disk).
            throw ModelDeliveryError.downloadFailed(error.localizedDescription)
        }
    }

    // MARK: - The two-transport transfer

    /// Fetches the snapshot: the small files through the Hub, the weight files
    /// through this package's own resumable transfer, reporting one
    /// byte-weighted fraction across both.
    private func transferSnapshot(report: @Sendable @escaping (Double) -> Void) async throws {
        let hub = self.hub
        let repo = HubApi.Repo(id: spec.repoID)

        let weightNames = try await hub.getFilenames(from: repo, matching: spec.weightGlobs)
        var weights: [(name: String, metadata: HubApi.FileMetadata)] = []
        for name in weightNames {
            guard let metadata = try await hub.getFileMetadata(from: repo, matching: [name]).first else {
                throw ModelDeliveryError.missingFileMetadata(file: name)
            }
            weights.append((name, metadata))
        }

        let configBytes = try await hub.getFileMetadata(from: repo, matching: spec.configGlobs)
            .reduce(Int64(0)) { $0 + Int64($1.size ?? 0) }
        let budget = SnapshotDownloadBudget(
            configBytes: configBytes,
            weightBytes: weights.reduce(Int64(0)) { $0 + Int64($1.metadata.size ?? 0) }
        )
        // Weight bytes an earlier attempt already committed: counted from the
        // start so a resumed download's bar continues instead of restarting.
        let alreadyCommitted = weights.reduce(Int64(0)) { total, weight in
            total + ResumableFileDownload.byteCount(at: snapshotDirectory.appending(path: weight.name))
        }
        let tally = SnapshotDownloadTally(budget: budget, committedWeightBytes: alreadyCommitted)
        report(tally.fraction)

        // The small files first: quick, and it gets the tokenizer and configs
        // on disk early so a snapshot interrupted mid-weights is one file from
        // complete. The Hub skips whatever is already committed.
        _ = try await hub.snapshot(from: repo, matching: spec.configGlobs) { snapshotProgress in
            report(tally.noteConfigFraction(snapshotProgress.fractionCompleted))
        }
        report(tally.noteConfigFraction(1))

        for weight in weights {
            try Task.checkCancellation()
            let destination = snapshotDirectory.appending(path: weight.name)
            let expected = weight.metadata.size.map(Int64.init)

            // Already committed at the published size: leave it alone (this is
            // what makes a re-run after a partial snapshot cheap) but make sure
            // the Hub sidecar is there, since a file this package wrote is
            // otherwise invisible to the Hub's own resume bookkeeping.
            if let expected, ResumableFileDownload.byteCount(at: destination) == expected {
                try writeHubSidecar(for: weight.name, metadata: weight.metadata)
                report(tally.commitWeightFile(bytes: expected))
                continue
            }

            guard let location = URL(string: weight.metadata.location) else {
                throw ModelDeliveryError.missingFileMetadata(file: weight.name)
            }
            let partial = partialFileURL(for: weight.name)
            let bytes = try await ResumableFileDownload.fetch(
                from: location,
                expectedBytes: expected,
                into: partial,
                progress: { report(tally.noteWeightBytes($0)) }
            )
            try commitWeightFile(at: partial, to: destination, name: weight.name, metadata: weight.metadata)
            report(tally.commitWeightFile(bytes: bytes))
        }
    }

    /// Moves a completed transfer into the snapshot directory, verifying it
    /// first. For LFS files the Hub's etag IS the sha256 of the content
    /// (measured against a file the Hub itself downloaded), so this is a real
    /// end-to-end integrity check on a resumed, range-stitched transfer — the
    /// one place a silent corruption could otherwise enter the snapshot.
    func commitWeightFile(
        at partial: URL,
        to destination: URL,
        name: String,
        metadata: HubApi.FileMetadata
    ) throws {
        if let etag = metadata.etag, Self.isSHA256(etag) {
            guard try Self.sha256Hex(of: partial) == etag else {
                try? FileManager.default.removeItem(at: partial)
                throw ModelDeliveryError.integrityCheckFailed(file: name)
            }
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: partial, to: destination)
        try writeHubSidecar(for: name, metadata: metadata)
    }

    /// Writes the `.metadata` sidecar the Hub keeps for every file it manages
    /// (`commitHash\netag\ntimestamp`), so a file this package transferred is
    /// indistinguishable from one the Hub fetched: its download pass returns
    /// early on the etag match instead of re-fetching, and its offline pass
    /// stops rejecting the repo directory for a file without a sidecar.
    func writeHubSidecar(for name: String, metadata: HubApi.FileMetadata) throws {
        guard let commitHash = metadata.commitHash, let etag = metadata.etag else { return }
        let sidecar =
            snapshotDirectory
            .appending(path: ".cache", directoryHint: .isDirectory)
            .appending(path: "huggingface", directoryHint: .isDirectory)
            .appending(path: "download", directoryHint: .isDirectory)
            .appending(path: name + ".metadata", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: sidecar.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = "\(commitHash)\n\(etag)\n\(Date().timeIntervalSince1970)\n"
        try contents.write(to: sidecar, atomically: true, encoding: .utf8)
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    /// Streamed so a 3 GB file is hashed without being held in memory.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The highest fraction a download has reached, so a stall retry's progress
/// report does not snap the bar backwards. Lock-guarded because the callbacks
/// arrive on URLSession worker threads while the retry reads from its own task.
final class HighWaterFraction: Sendable {

    private let fraction = Mutex(0.0)

    func update(_ new: Double) {
        fraction.withLock { $0 = max($0, new) }
    }

    var value: Double {
        fraction.withLock { $0 }
    }
}
