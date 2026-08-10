//
//  RetiredModelCleanupTests.swift
//  EchoTests
//
//  The retired-model cleanup discipline (ADR-011), asserted through the
//  public seam against throwaway temp roots — NEVER the real
//  EchoPaths.modelsDirectory. The real deletion of a user's Gemma snapshot
//  happens exactly once, in the launched app; these tests prove the
//  discipline that makes that deletion safe: named-directory scope (never a
//  sweep of the shared models root), idempotent no-op when already gone,
//  non-fatal failure retried on the next launch, and staging-only partials
//  covered the same as complete snapshots.
//

import Foundation
import Hub
import Testing
@testable import Echo

@Suite("Retired-model cleanup (ADR-011)")
struct RetiredModelCleanupTests {

    /// The one real entry in production's retired list today.
    private static let retiredID = "mlx-community/gemma-4-12B-it-qat-OptiQ-4bit"

    // MARK: - Fixtures

    /// One test's throwaway on-disk world. The machine-safety rule for this
    /// suite is temp roots only — production's default `modelsRoot` must
    /// never be exercised from a test.
    private struct TempWorld {
        /// Unique temp container holding everything below; `destroy()` removes it.
        let container: URL
        /// Stand-in for ~/Library/Application Support/Echo/Models.
        let modelsRoot: URL
        /// A meetings-root stand-in OUTSIDE the models root — the cleanup
        /// must never reach past its own root.
        let meetingsRoot: URL

        static func make() throws -> TempWorld {
            let container = FileManager.default.temporaryDirectory
                .appending(path: "RetiredModelCleanupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            let world = TempWorld(
                container: container,
                modelsRoot: container.appending(path: "Models", directoryHint: .isDirectory),
                meetingsRoot: container.appending(path: "Meetings", directoryHint: .isDirectory)
            )
            try FileManager.default.createDirectory(at: world.modelsRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: world.meetingsRoot, withIntermediateDirectories: true)
            return world
        }

        func destroy() {
            try? FileManager.default.removeItem(at: container)
        }
    }

    /// models/<org>/<repo> under a root — the Hub snapshot layout. Built
    /// literally here (not through HubApi) on purpose: the test pins the real
    /// on-disk contract, so a drift in production's derivation fails loudly
    /// instead of being followed silently.
    private func repoDirectory(for repoID: String, under modelsRoot: URL) -> URL {
        modelsRoot.appending(path: "models").appending(path: repoID)
    }

    /// Writes `contents` at `url`, creating intermediate directories.
    private func write(_ contents: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    /// A realistic retired-repo directory: weight shards, configs, and the
    /// Hub's resumable staging under .cache/ — the layout
    /// `partialDownloadBytes()` observes in production. Removing the one
    /// repo directory must cover all of it.
    private func populateRetiredRepo(at directory: URL) throws {
        try write("fake shard 1", at: directory.appending(path: "model-00001-of-00002.safetensors"))
        try write("fake shard 2", at: directory.appending(path: "model-00002-of-00002.safetensors"))
        try write("{}", at: directory.appending(path: "config.json"))
        try write("{}", at: directory.appending(path: "tokenizer.json"))
        try write(
            "half-downloaded bytes",
            at: directory.appending(path: ".cache/huggingface/download/model-00001-of-00002.safetensors.abc123.incomplete")
        )
    }

    /// The injectable deletion seam, instrumented: counts removal attempts
    /// and can be scripted to fail, so "no attempt when already gone",
    /// "failure is non-fatal", and "retry next launch" are all observable
    /// without manufacturing real permission errors. When not failing it
    /// performs the real removal, so retry runs prove actual deletion.
    private final class CountingRemover: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var urls: [URL] = []
        private var fails: Bool

        init(fails: Bool = false) { self.fails = fails }

        struct StubbedRemovalError: Error {}

        var remove: @Sendable (URL) throws -> Void {
            { [self] url in
                lock.lock()
                count += 1
                urls.append(url)
                let shouldFail = fails
                lock.unlock()
                if shouldFail { throw StubbedRemovalError() }
                try FileManager.default.removeItem(at: url)
            }
        }

        /// The scripted failure clears — models a file lock releasing before
        /// the next launch.
        func setFails(_ newValue: Bool) { lock.lock(); fails = newValue; lock.unlock() }
        var removeCount: Int { lock.lock(); defer { lock.unlock() }; return count }
        /// What was actually targeted — the named-scope assertion.
        var removedURLs: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    /// Every regular file under `root`, keyed by relative path, with full
    /// contents — "untouched" must mean byte-for-byte identical, not merely
    /// still present. Path-based enumeration sidesteps the /private symlink
    /// prefix macOS puts on temp URLs.
    private func fingerprint(of root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return files }
        for case let relativePath as String in enumerator {
            let url = root.appending(path: relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            files[relativePath] = try Data(contentsOf: url)
        }
        return files
    }

    // MARK: - Behavior 1: the retired directory is deleted whole

    @Test("a retired snapshot on disk — weights, configs, .cache staging — is deleted entirely")
    func retiredDirectoryRemovedEntirely() throws {
        let world = try TempWorld.make()
        defer { world.destroy() }
        let retired = repoDirectory(for: Self.retiredID, under: world.modelsRoot)
        try populateRetiredRepo(at: retired)

        RetiredModelCleanup.run(
            retiredRepoIDs: [Self.retiredID],
            modelsRoot: world.modelsRoot
        )

        #expect(!FileManager.default.fileExists(atPath: retired.path))
    }

    // MARK: - Behavior 2: named-directory removal, never a sweep

    @Test("every sibling — the new model, other models' stand-ins, meetings — survives byte-for-byte")
    func siblingsUntouchedByteForByte() throws {
        let world = try TempWorld.make()
        defer { world.destroy() }
        let retired = repoDirectory(for: Self.retiredID, under: world.modelsRoot)
        try populateRetiredRepo(at: retired)

        // The shared models root, as production knows it: the CURRENT summary
        // model (same org directory as the retired one — the closest possible
        // neighbor), the speech model, and a future embeddings model. Plus
        // meeting data outside the models root entirely.
        let qwen = repoDirectory(for: SummaryModelManager.modelID, under: world.modelsRoot)
        try write("qwen weights", at: qwen.appending(path: "model.safetensors"))
        try write("{}", at: qwen.appending(path: "config.json"))
        try write(
            "qwen partial",
            at: qwen.appending(path: ".cache/huggingface/download/model.safetensors.def456.incomplete")
        )
        // The transcription model, which uses a FLAT repo folder under the
        // models root rather than the models/<org>/<repo> layout — it must
        // survive every cleanup untouched.
        let parakeet = world.modelsRoot.appending(path: "parakeet-tdt-0.6b-v3-coreml", directoryHint: .isDirectory)
        try write("parakeet weights", at: parakeet.appending(path: "Encoder.mlmodelc/model.mil"))
        let embeddings = repoDirectory(for: "mlx-community/embeddinggemma-300m-bf16", under: world.modelsRoot)
        try write("embedding weights", at: embeddings.appending(path: "model.safetensors"))
        try write("a meeting", at: world.meetingsRoot.appending(path: "2026-07-28-standup/meeting.json"))

        let before = try (
            qwen: fingerprint(of: qwen),
            parakeet: fingerprint(of: parakeet),
            embeddings: fingerprint(of: embeddings),
            meetings: fingerprint(of: world.meetingsRoot)
        )

        RetiredModelCleanup.run(
            retiredRepoIDs: [Self.retiredID],
            modelsRoot: world.modelsRoot
        )

        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(try fingerprint(of: qwen) == before.qwen)
        #expect(try fingerprint(of: parakeet) == before.parakeet)
        #expect(try fingerprint(of: embeddings) == before.embeddings)
        #expect(try fingerprint(of: world.meetingsRoot) == before.meetings)
    }

    // MARK: - Behavior 3: already gone is a satisfied no-op

    @Test("an absent retired directory attempts no deletion — the every-launch run is a true no-op")
    func absentRetiredDirectoryAttemptsNothing() throws {
        let world = try TempWorld.make()
        defer { world.destroy() }
        // No retired directory anywhere — the post-migration steady state
        // every subsequent launch sees.
        let remover = CountingRemover()

        RetiredModelCleanup.run(
            retiredRepoIDs: [Self.retiredID],
            modelsRoot: world.modelsRoot,
            remove: remover.remove
        )

        #expect(remover.removeCount == 0)
    }

    // MARK: - Behavior 4: failure is non-fatal and retried by the next launch

    @Test("a failed deletion leaves everything intact and the next launch's run deletes it")
    func failedDeletionRetriesNextLaunch() throws {
        let world = try TempWorld.make()
        defer { world.destroy() }
        let retired = repoDirectory(for: Self.retiredID, under: world.modelsRoot)
        try populateRetiredRepo(at: retired)
        let parakeet = world.modelsRoot.appending(path: "parakeet-tdt-0.6b-v3-coreml", directoryHint: .isDirectory)
        try write("parakeet weights", at: parakeet.appending(path: "Encoder.mlmodelc/model.mil"))
        let beforeParakeet = try fingerprint(of: parakeet)
        let beforeRetired = try fingerprint(of: retired)
        let remover = CountingRemover(fails: true)

        // Launch 1: the delete fails (file lock, permission…). `run` must not
        // throw out (its signature can't — this call compiling is the proof),
        // and the failure must leave the world exactly as it found it.
        RetiredModelCleanup.run(
            retiredRepoIDs: [Self.retiredID],
            modelsRoot: world.modelsRoot,
            remove: remover.remove
        )

        #expect(remover.removeCount == 1)
        #expect(try fingerprint(of: retired) == beforeRetired)
        #expect(try fingerprint(of: parakeet) == beforeParakeet)

        // Launch 2: the lock is gone. No persisted trigger state to consult —
        // repetition alone makes the obligation durable.
        remover.setFails(false)
        RetiredModelCleanup.run(
            retiredRepoIDs: [Self.retiredID],
            modelsRoot: world.modelsRoot,
            remove: remover.remove
        )

        #expect(remover.removeCount == 2)
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(try fingerprint(of: parakeet) == beforeParakeet)
    }

    // MARK: - Behavior 5: staging-only partials are covered the same

    @Test("a retired directory holding only .cache staging is removed; its emptied org directory is left alone")
    func partialOnlyLayoutRemoved() throws {
        let world = try TempWorld.make()
        defer { world.destroy() }
        // A download interrupted before any file committed (SP-004 story 7):
        // nothing in the repo directory but the Hub's resumable staging.
        let retired = repoDirectory(for: Self.retiredID, under: world.modelsRoot)
        try write(
            "half-downloaded bytes",
            at: retired.appending(path: ".cache/huggingface/download/model-00001-of-00002.safetensors.abc123.incomplete")
        )

        RetiredModelCleanup.run(
            retiredRepoIDs: [Self.retiredID],
            modelsRoot: world.modelsRoot
        )

        #expect(!FileManager.default.fileExists(atPath: retired.path))
        // The removal stops at the repo directory: the parent org directory
        // survives even now that it is empty — cleanup never walks upward.
        var isDirectory: ObjCBool = false
        let orgDirectory = retired.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: orgDirectory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    // MARK: - Behavior 6: an empty retired list touches nothing

    @Test("an empty retired list attempts nothing — the guard a future migration inherits")
    func emptyRetiredListTouchesNothing() throws {
        let world = try TempWorld.make()
        defer { world.destroy() }
        // Even a directory matching today's retired id must survive: with no
        // ids listed there is nothing retired, whatever else is on disk.
        let gemmaLookalike = repoDirectory(for: Self.retiredID, under: world.modelsRoot)
        try populateRetiredRepo(at: gemmaLookalike)
        let before = try fingerprint(of: world.modelsRoot)
        let remover = CountingRemover()

        RetiredModelCleanup.run(
            retiredRepoIDs: [],
            retiredFileNames: [],
            modelsRoot: world.modelsRoot,
            remove: remover.remove
        )

        #expect(remover.removeCount == 0)
        #expect(try fingerprint(of: world.modelsRoot) == before)
    }

    // MARK: - Behavior 7: retired loose files

    @Test("a retired loose file is deleted; an absent one attempts nothing")
    func retiredLooseFileRemoved() throws {
        let world = try TempWorld.make()
        defer { world.destroy() }
        let manifest = world.modelsRoot.appending(path: "final-pass-model-manifest.json")
        try write("{}", at: manifest)
        // A sibling file the list does not name must survive — the same
        // named-target scope the repo deletions have.
        let keeper = world.modelsRoot.appending(path: "summary-model-manifest.json")
        try write("{}", at: keeper)
        let remover = CountingRemover()

        RetiredModelCleanup.run(
            retiredRepoIDs: [],
            retiredFileNames: ["final-pass-model-manifest.json"],
            modelsRoot: world.modelsRoot,
            remove: remover.remove
        )

        #expect(remover.removeCount == 1)
        #expect(remover.removedURLs == [manifest])
        #expect(FileManager.default.fileExists(atPath: keeper.path))

        // Second launch: already gone (the run above deleted it), so no
        // attempt at all — idempotent by repetition, no persisted trigger.
        #expect(!FileManager.default.fileExists(atPath: manifest.path))
        let second = CountingRemover()
        RetiredModelCleanup.run(
            retiredRepoIDs: [],
            retiredFileNames: ["final-pass-model-manifest.json"],
            modelsRoot: world.modelsRoot,
            remove: second.remove
        )
        #expect(second.removeCount == 0)
    }

    // MARK: - Behavior 8: layout parity across the Hub client swap

    /// The guarantee that made retiring the Argmax package a zero-migration
    /// swap: swift-transformers' `HubApi` computes the SAME
    /// `<downloadBase>/models/<org>/<repo>` path the vendored client did, so
    /// the summary model's existing snapshot keeps loading and this cleanup
    /// keeps targeting the right directory. Pinned executably, against the
    /// literal path — if the layout ever drifts, both break here first.
    @Test("HubApi's repo location is downloadBase/models/<org>/<repo>")
    func hubLayoutParity() throws {
        let world = try TempWorld.make()
        defer { world.destroy() }
        let repoID = "mlx-community/Qwen3.5-4B-OptiQ-4bit"

        let resolved = HubApi(downloadBase: world.modelsRoot, cache: nil)
            .localRepoLocation(HubApi.Repo(id: repoID))

        #expect(resolved == repoDirectory(for: repoID, under: world.modelsRoot))
        #expect(resolved.path == world.modelsRoot.appending(path: "models/\(repoID)").path)
    }
}
