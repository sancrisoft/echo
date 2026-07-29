//
//  SnapshotCompletenessTests.swift
//  EchoTests
//
//  The executable form of ADR-012: "snapshot complete on disk" derives from a
//  local manifest recording the downloader's actually-resolved file set —
//  never from a hardcoded layout or the presence of a sharding index. The
//  table covers both worlds (multi-shard-with-index and single-file-without)
//  plus both prohibited outcomes: a half-downloaded snapshot reading as ready,
//  and a complete one reading forever-incomplete (the live Qwen bug: the
//  repo's index references a vision sidecar the download deliberately
//  excludes). Real-FS temp URLs, mirroring SummaryModelPathsTests /
//  MeetingStoreTests; the real models root is never touched (SP-004 Testing
//  Decisions, layer 2).
//

import Foundation
import Testing
@testable import Echo

@Suite("Snapshot completeness (ADR-012)")
struct SnapshotCompletenessTests {

    private let modelID = "test-org/test-model"

    // MARK: - Fixture helpers (throwaway real-FS roots)

    /// A fresh throwaway root standing in for the models root: the snapshot
    /// directory lives at models/<org>/<repo> inside it and the manifest
    /// beside the models tree, mirroring the production layout.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SnapshotCompletenessTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSnapshotDirectory(in root: URL) throws -> URL {
        let directory = root.appending(path: "models/\(modelID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func manifestURL(in root: URL) -> URL {
        root.appending(path: "summary-model-manifest.json", directoryHint: .notDirectory)
    }

    /// Creates small stand-in files at the given repo-relative paths.
    private func touch(_ relativePaths: [String], in directory: URL) throws {
        for path in relativePaths {
            let url = directory.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("stub-bytes".utf8).write(to: url)
        }
    }

    /// The expected new-world shape: one weight file, no sharding index.
    private let singleFileLayout = [
        "config.json",
        "generation_config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "model.safetensors",
    ]

    /// The old-world shape (the retired 12B): sharded weights plus the
    /// sharding index — under the manifest rule the index is just one more
    /// recorded file, required because it was fetched, never parsed.
    private let multiShardLayout = [
        "config.json",
        "generation_config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "model-00001-of-00002.safetensors",
        "model-00002-of-00002.safetensors",
        "model.safetensors.index.json",
    ]

    // MARK: - Tracer: the new-world shape

    @Test("single-file layout with a manifest and every file on disk is complete")
    func singleFileLayoutComplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeSnapshotDirectory(in: root)
        try touch(singleFileLayout, in: directory)
        try SnapshotManifest(modelID: modelID, files: singleFileLayout)
            .write(to: manifestURL(in: root))

        #expect(SnapshotManifest.snapshotComplete(
            forModelID: modelID, in: directory, manifestAt: manifestURL(in: root)
        ))
    }

    /// Layout-agnostic in the other direction: the multi-shard-with-index
    /// world behaves identically — same rule, no per-layout code.
    @Test("multi-shard layout with a manifest and every file on disk is complete")
    func multiShardLayoutComplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeSnapshotDirectory(in: root)
        try touch(multiShardLayout, in: directory)
        try SnapshotManifest(modelID: modelID, files: multiShardLayout)
            .write(to: manifestURL(in: root))

        #expect(SnapshotManifest.snapshotComplete(
            forModelID: modelID, in: directory, manifestAt: manifestURL(in: root)
        ))
    }

    // MARK: - Half-downloaded must never read as ready

    @Test("single-file layout with the tokenizer file missing is incomplete")
    func missingTokenizerFileIsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeSnapshotDirectory(in: root)
        try touch(singleFileLayout.filter { $0 != "tokenizer.json" }, in: directory)
        try SnapshotManifest(modelID: modelID, files: singleFileLayout)
            .write(to: manifestURL(in: root))

        #expect(!SnapshotManifest.snapshotComplete(
            forModelID: modelID, in: directory, manifestAt: manifestURL(in: root)
        ))
    }

    @Test("multi-shard layout with one shard missing is incomplete")
    func missingShardIsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeSnapshotDirectory(in: root)
        try touch(
            multiShardLayout.filter { $0 != "model-00002-of-00002.safetensors" },
            in: directory
        )
        try SnapshotManifest(modelID: modelID, files: multiShardLayout)
            .write(to: manifestURL(in: root))

        #expect(!SnapshotManifest.snapshotComplete(
            forModelID: modelID, in: directory, manifestAt: manifestURL(in: root)
        ))
    }

    /// An interrupted first download: everything still lives in the Hub's
    /// `.cache` staging as resumable `*.incomplete` partials, nothing is
    /// committed at the manifest's paths. Staging never counts.
    @Test("staging-only directory (.cache partials, nothing committed) is incomplete")
    func stagingOnlyIsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeSnapshotDirectory(in: root)
        try touch(
            singleFileLayout.map { ".cache/huggingface/download/\($0).abc123.incomplete" },
            in: directory
        )
        try SnapshotManifest(modelID: modelID, files: singleFileLayout)
            .write(to: manifestURL(in: root))

        #expect(!SnapshotManifest.snapshotComplete(
            forModelID: modelID, in: directory, manifestAt: manifestURL(in: root)
        ))
    }

    // MARK: - The live S1 bug, dead

    /// The exact failure this slice kills: the real Qwen repo's sharding
    /// index references BOTH the downloaded weight file AND a vision sidecar
    /// (optiq/optiq_vision.safetensors) the download globs deliberately
    /// exclude. The old index-derived rule read this COMPLETE snapshot as
    /// forever-incomplete; under the manifest rule the index is never parsed,
    /// so the snapshot is complete without the sidecar ever existing.
    @Test("real Qwen inventory is complete without the excluded vision sidecar")
    func qwenInventoryCompleteWithoutVisionSidecar() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeSnapshotDirectory(in: root)

        // The inventory the globs actually fetch (S1 ground truth), minus the
        // index written explicitly below with its real weight_map shape.
        let fetched = [
            "config.json",
            "generation_config.json",
            "kv_config.json",
            "optiq_metadata.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "model.safetensors",
        ]
        try touch(fetched, in: directory)
        let index = """
        {
          "metadata": { "total_size": 3270000000 },
          "weight_map": {
            "model.embed_tokens.weight": "model.safetensors",
            "vision_tower.encoder.weight": "optiq/optiq_vision.safetensors"
          }
        }
        """
        try Data(index.utf8).write(to: directory.appending(path: "model.safetensors.index.json"))

        let inventory = fetched + ["model.safetensors.index.json"]
        try SnapshotManifest(modelID: modelID, files: inventory)
            .write(to: manifestURL(in: root))

        // Complete — and provably WITHOUT the sidecar the index references.
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "optiq/optiq_vision.safetensors").path
        ))
        #expect(SnapshotManifest.snapshotComplete(
            forModelID: modelID, in: directory, manifestAt: manifestURL(in: root)
        ))
    }

    // MARK: - No manifest, no completeness claim (fail-safe direction)

    /// A complete-looking directory without a manifest reads incomplete —
    /// this is the accepted migration trade-off for snapshots that predate
    /// the manifest mechanism: the next online pass no-ops per committed
    /// file and records the first manifest (ADR-012).
    @Test("manifest absent reads incomplete even with every file on disk")
    func manifestAbsentIsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeSnapshotDirectory(in: root)
        try touch(singleFileLayout, in: directory)

        #expect(!SnapshotManifest.snapshotComplete(
            forModelID: modelID, in: directory, manifestAt: manifestURL(in: root)
        ))
    }

    @Test("corrupted manifest reads incomplete and never throws")
    func corruptedManifestIsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeSnapshotDirectory(in: root)
        try touch(singleFileLayout, in: directory)
        // Not JSON at all — a torn write or bit rot must degrade to the
        // resume path, never to a crash or a false "ready".
        try Data("{not json ⚠︎".utf8).write(to: manifestURL(in: root))

        #expect(!SnapshotManifest.snapshotComplete(
            forModelID: modelID, in: directory, manifestAt: manifestURL(in: root)
        ))
    }

    /// Model-id scoping (ADR-012's invalidated-with-the-model-id rule): after
    /// a model swap, the retired model's manifest is a stale record that must
    /// read as "no manifest" for the new model — even if file names overlap.
    @Test("manifest written for a different model id reads incomplete")
    func foreignModelManifestIsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeSnapshotDirectory(in: root)
        try touch(singleFileLayout, in: directory)
        try SnapshotManifest(modelID: "test-org/retired-model", files: singleFileLayout)
            .write(to: manifestURL(in: root))

        #expect(!SnapshotManifest.snapshotComplete(
            forModelID: modelID, in: directory, manifestAt: manifestURL(in: root)
        ))
    }

    /// "Every file of zero files is on disk" is vacuously true — and a false
    /// "ready" over an empty record is exactly the prohibited direction, so
    /// an empty file set must read incomplete no matter what's on disk.
    @Test("manifest with an empty file set reads incomplete")
    func emptyFileSetIsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeSnapshotDirectory(in: root)
        try touch(singleFileLayout, in: directory)
        try SnapshotManifest(modelID: modelID, files: [])
            .write(to: manifestURL(in: root))

        #expect(!SnapshotManifest.snapshotComplete(
            forModelID: modelID, in: directory, manifestAt: manifestURL(in: root)
        ))
    }

    // MARK: - The record itself

    /// The record round-trips losslessly, an overwrite yields exactly the new
    /// record (each download supersedes the last — no merging), and the
    /// atomic write leaves no temp litter next to the manifest.
    @Test("manifest write round-trips, overwrites cleanly, and leaves no litter")
    func manifestWriteRoundTrips() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = manifestURL(in: root)

        let first = SnapshotManifest(modelID: modelID, files: multiShardLayout)
        try first.write(to: url)
        #expect(SnapshotManifest.read(from: url) == first)

        let second = SnapshotManifest(modelID: "test-org/next-model", files: singleFileLayout)
        try second.write(to: url)
        #expect(SnapshotManifest.read(from: url) == second)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(siblings == [url.lastPathComponent])
    }
}
