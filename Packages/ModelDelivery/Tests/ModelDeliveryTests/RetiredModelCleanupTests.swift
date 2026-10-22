//
//  RetiredModelCleanupTests.swift
//  ModelDeliveryTests
//
//  The retired-model cleanup discipline, asserted through the public seam
//  against throwaway temp roots — never the real models root. The real
//  deletion of a user's retired snapshot happens exactly once, in the launched
//  app; these tests prove the discipline that makes that deletion safe:
//  named-directory scope (never a sweep of the shared models root), an
//  idempotent no-op when it is already gone, a non-fatal failure retried on the
//  next launch, and staging-only partials covered the same as complete
//  snapshots.
//
//  Ported from the PoC's RetiredModelCleanupTests. One API change: `modelsRoot`
//  is now required rather than defaulted to the real data root, so a test that
//  forgets the argument cannot reach the user's folder — it no longer compiles.
//

import EchoCoreTestSupport
import Foundation
import Hub
import ModelDelivery
import Synchronization
import Testing

@Suite("Retired model cleanup")
struct RetiredModelCleanupTests {

    /// One of the real entries in production's retired list.
    private static let retiredID = "mlx-community/gemma-4-12B-it-qat-OptiQ-4bit"

    /// The current summary model, as a neighbour that must survive. A literal
    /// rather than an import: this package deliberately holds no model
    /// identity of its own, so the id lives with the test that needs it.
    private static let currentSummaryID = "mlx-community/Qwen3.5-4B-OptiQ-4bit"

    // MARK: - Fixtures

    /// One test's throwaway on-disk world, built inside a `TemporaryDirectory`.
    private struct TempWorld {

        /// Stand-in for the app's Models directory.
        let modelsRoot: URL

        /// A meetings-root stand-in OUTSIDE the models root — the cleanup must
        /// never reach past its own root.
        let meetingsRoot: URL

        init(container: URL) throws {
            modelsRoot = container.appending(path: "Models", directoryHint: .isDirectory)
            meetingsRoot = container.appending(path: "Meetings", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)
        }
    }

    /// models/<org>/<repo> under a root — the Hub snapshot layout. Built
    /// literally here (not through `HubApi`) on purpose: the test pins the real
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
    /// Hub's resumable staging under `.cache/` — the layout
    /// `partialDownloadBytes()` observes in production. Removing the one repo
    /// directory must cover all of it.
    private func populateRetiredRepo(at directory: URL) throws {
        try write("fake shard 1", at: directory.appending(path: "model-00001-of-00002.safetensors"))
        try write("fake shard 2", at: directory.appending(path: "model-00002-of-00002.safetensors"))
        try write("{}", at: directory.appending(path: "config.json"))
        try write("{}", at: directory.appending(path: "tokenizer.json"))
        try write(
            "half-downloaded bytes",
            at: directory.appending(
                path: ".cache/huggingface/download/model-00001-of-00002.safetensors.abc123.incomplete"
            )
        )
    }

    /// The injectable deletion seam, instrumented: counts removal attempts and
    /// can be scripted to fail, so "no attempt when already gone", "failure is
    /// non-fatal", and "retry next launch" are all observable without
    /// manufacturing real permission errors. When not failing it performs the
    /// real removal, so retry runs prove actual deletion.
    private final class CountingRemover: Sendable {

        private struct State {
            var count = 0
            var urls: [URL] = []
            var fails: Bool
        }

        private let state: Mutex<State>

        init(fails: Bool = false) {
            state = Mutex(State(fails: fails))
        }

        struct StubbedRemovalError: Error {}

        var remove: @Sendable (URL) throws -> Void {
            { [self] url in
                let shouldFail = state.withLock { current in
                    current.count += 1
                    current.urls.append(url)
                    return current.fails
                }
                if shouldFail { throw StubbedRemovalError() }
                try FileManager.default.removeItem(at: url)
            }
        }

        /// The scripted failure clears — models a file lock releasing before
        /// the next launch.
        func setFails(_ newValue: Bool) { state.withLock { $0.fails = newValue } }

        var removeCount: Int { state.withLock { $0.count } }

        /// What was actually targeted — the named-scope assertion.
        var removedURLs: [URL] { state.withLock { $0.urls } }
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
                !isDirectory.boolValue
            else { continue }
            files[relativePath] = try Data(contentsOf: url)
        }
        return files
    }

    // MARK: - Behavior 1: the retired directory is deleted whole

    @Test("a retired snapshot on disk — weights, configs, staging — is deleted entirely")
    func retiredDirectoryRemovedEntirely() throws {
        let temp = try TemporaryDirectory(prefix: "RetiredModelCleanupTests")
        defer { temp.remove() }
        let world = try TempWorld(container: temp.url)
        let retired = repoDirectory(for: Self.retiredID, under: world.modelsRoot)
        try populateRetiredRepo(at: retired)

        RetiredModelCleanup.run(
            retiredRepoIDs: [Self.retiredID],
            modelsRoot: world.modelsRoot
        )

        #expect(!FileManager.default.fileExists(atPath: retired.path))
    }

    // MARK: - Behavior 2: named-directory removal, never a sweep

    @Test("every sibling — the new model, other models, meetings — survives byte-for-byte")
    func siblingsUntouchedByteForByte() throws {
        let temp = try TemporaryDirectory(prefix: "RetiredModelCleanupTests")
        defer { temp.remove() }
        let world = try TempWorld(container: temp.url)
        let retired = repoDirectory(for: Self.retiredID, under: world.modelsRoot)
        try populateRetiredRepo(at: retired)

        // The shared models root, as production knows it: the CURRENT summary
        // model (same org directory as the retired one — the closest possible
        // neighbour), the speech model, and a future embeddings model. Plus
        // meeting data outside the models root entirely.
        let summary = repoDirectory(for: Self.currentSummaryID, under: world.modelsRoot)
        try write("summary weights", at: summary.appending(path: "model.safetensors"))
        try write("{}", at: summary.appending(path: "config.json"))
        try write(
            "summary partial",
            at: summary.appending(path: ".cache/huggingface/download/model.safetensors.def456.incomplete")
        )
        // The transcription model, which uses a FLAT repo folder under the
        // models root rather than the models/<org>/<repo> layout — it must
        // survive every cleanup untouched.
        let parakeet = world.modelsRoot.appending(path: "parakeet-tdt-0.6b-v3-coreml", directoryHint: .isDirectory)
        try write("parakeet weights", at: parakeet.appending(path: "Encoder.mlmodelc/model.mil"))
        let embeddings = repoDirectory(for: "mlx-community/embeddinggemma-300m-bf16", under: world.modelsRoot)
        try write("embedding weights", at: embeddings.appending(path: "model.safetensors"))
        try write("a meeting", at: world.meetingsRoot.appending(path: "2026-07-28-standup/meeting.json"))

        let beforeSummary = try fingerprint(of: summary)
        let beforeParakeet = try fingerprint(of: parakeet)
        let beforeEmbeddings = try fingerprint(of: embeddings)
        let beforeMeetings = try fingerprint(of: world.meetingsRoot)

        RetiredModelCleanup.run(
            retiredRepoIDs: [Self.retiredID],
            modelsRoot: world.modelsRoot
        )

        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(try fingerprint(of: summary) == beforeSummary)
        #expect(try fingerprint(of: parakeet) == beforeParakeet)
        #expect(try fingerprint(of: embeddings) == beforeEmbeddings)
        #expect(try fingerprint(of: world.meetingsRoot) == beforeMeetings)
    }

    // MARK: - Behavior 3: already gone is a satisfied no-op

    @Test("an absent retired directory attempts no deletion — the every-launch run is a true no-op")
    func absentRetiredDirectoryAttemptsNothing() throws {
        let temp = try TemporaryDirectory(prefix: "RetiredModelCleanupTests")
        defer { temp.remove() }
        let world = try TempWorld(container: temp.url)
        // No retired directory anywhere — the post-migration steady state every
        // subsequent launch sees.
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
        let temp = try TemporaryDirectory(prefix: "RetiredModelCleanupTests")
        defer { temp.remove() }
        let world = try TempWorld(container: temp.url)
        let retired = repoDirectory(for: Self.retiredID, under: world.modelsRoot)
        try populateRetiredRepo(at: retired)
        let parakeet = world.modelsRoot.appending(path: "parakeet-tdt-0.6b-v3-coreml", directoryHint: .isDirectory)
        try write("parakeet weights", at: parakeet.appending(path: "Encoder.mlmodelc/model.mil"))
        let beforeParakeet = try fingerprint(of: parakeet)
        let beforeRetired = try fingerprint(of: retired)
        let remover = CountingRemover(fails: true)

        // Launch 1: the delete fails (file lock, permission…). `run` must not
        // throw out — its signature cannot, and this call compiling is the
        // proof — and the failure must leave the world exactly as it found it.
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

    @Test("a retired directory holding only staging is removed; its emptied org directory is left alone")
    func partialOnlyLayoutRemoved() throws {
        let temp = try TemporaryDirectory(prefix: "RetiredModelCleanupTests")
        defer { temp.remove() }
        let world = try TempWorld(container: temp.url)
        // A download interrupted before any file committed: nothing in the repo
        // directory but the Hub's resumable staging.
        let retired = repoDirectory(for: Self.retiredID, under: world.modelsRoot)
        try write(
            "half-downloaded bytes",
            at: retired.appending(
                path: ".cache/huggingface/download/model-00001-of-00002.safetensors.abc123.incomplete"
            )
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
        let temp = try TemporaryDirectory(prefix: "RetiredModelCleanupTests")
        defer { temp.remove() }
        let world = try TempWorld(container: temp.url)
        // Even a directory matching today's retired id must survive: with no
        // ids listed there is nothing retired, whatever else is on disk.
        let lookalike = repoDirectory(for: Self.retiredID, under: world.modelsRoot)
        try populateRetiredRepo(at: lookalike)
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
        let temp = try TemporaryDirectory(prefix: "RetiredModelCleanupTests")
        defer { temp.remove() }
        let world = try TempWorld(container: temp.url)
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

        // Second launch: already gone (the run above deleted it), so no attempt
        // at all — idempotent by repetition, no persisted trigger.
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

    /// The guarantee that made retiring the vendored Hub client a
    /// zero-migration swap: swift-transformers' `HubApi` computes the SAME
    /// `<downloadBase>/models/<org>/<repo>` path the vendored client did, so an
    /// existing snapshot keeps loading and this cleanup keeps targeting the
    /// right directory. Pinned executably against the literal path — if the
    /// layout ever drifts, both break here first.
    @Test("the Hub's repo location is downloadBase/models/<org>/<repo>")
    func hubLayoutParity() throws {
        let temp = try TemporaryDirectory(prefix: "RetiredModelCleanupTests")
        defer { temp.remove() }
        let world = try TempWorld(container: temp.url)
        let repoID = Self.currentSummaryID

        let resolved = HubApi(downloadBase: world.modelsRoot, cache: nil)
            .localRepoLocation(HubApi.Repo(id: repoID))

        #expect(resolved == repoDirectory(for: repoID, under: world.modelsRoot))
        #expect(resolved.path == world.modelsRoot.appending(path: "models/\(repoID)").path)
    }
}
