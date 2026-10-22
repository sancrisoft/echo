//
//  SnapshotManifestTests.swift
//  ModelDeliveryTests
//
//  The executable form of the manifest rule (see `SnapshotManifest.swift`):
//  "snapshot complete on disk" derives from a local record of the downloader's
//  actually-resolved file set — never from a hardcoded layout, and never from
//  the presence of a sharding index.
//
//  Ported from the PoC's SnapshotCompletenessTests. The table covers both
//  worlds (multi-shard-with-index and single-file-without) plus both
//  prohibited outcomes: a half-downloaded snapshot reading as ready, and a
//  complete one reading forever-incomplete — the shipped bug, where the
//  summary repo's index references a vision sidecar the download globs
//  deliberately exclude.
//
//  Real-FS temp roots throughout, so the layouts are the ones production
//  observes; the real models root is never touched.
//

import EchoCoreTestSupport
import Foundation
import ModelDelivery
import Testing

@Suite("Snapshot manifest")
struct SnapshotManifestTests {

    private let modelID = "test-org/test-model"

    // MARK: - Fixture helpers (throwaway real-FS roots)

    /// The snapshot directory for `modelID` inside a models root: the Hub's
    /// models/<org>/<repo> layout, mirroring production.
    private func makeSnapshotDirectory(in root: URL) throws -> URL {
        let directory = root.appending(path: "models/\(modelID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The manifest sits beside the models tree, not inside the snapshot.
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

    @Test("a single-file layout with a manifest and every file on disk is complete")
    func singleFileLayoutComplete() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotManifestTests")
        defer { temp.remove() }
        let directory = try makeSnapshotDirectory(in: temp.url)
        try touch(singleFileLayout, in: directory)
        try SnapshotManifest(modelID: modelID, files: singleFileLayout)
            .write(to: manifestURL(in: temp.url))

        #expect(
            SnapshotManifest.snapshotComplete(
                forModelID: modelID,
                in: directory,
                manifestAt: manifestURL(in: temp.url)
            )
        )
    }

    /// Layout-agnostic in the other direction: the multi-shard-with-index
    /// world behaves identically — same rule, no per-layout code.
    @Test("a multi-shard layout with a manifest and every file on disk is complete")
    func multiShardLayoutComplete() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotManifestTests")
        defer { temp.remove() }
        let directory = try makeSnapshotDirectory(in: temp.url)
        try touch(multiShardLayout, in: directory)
        try SnapshotManifest(modelID: modelID, files: multiShardLayout)
            .write(to: manifestURL(in: temp.url))

        #expect(
            SnapshotManifest.snapshotComplete(
                forModelID: modelID,
                in: directory,
                manifestAt: manifestURL(in: temp.url)
            )
        )
    }

    // MARK: - Half-downloaded must never read as ready

    @Test("a single-file layout with the tokenizer file missing is incomplete")
    func missingTokenizerFileIsIncomplete() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotManifestTests")
        defer { temp.remove() }
        let directory = try makeSnapshotDirectory(in: temp.url)
        try touch(singleFileLayout.filter { $0 != "tokenizer.json" }, in: directory)
        try SnapshotManifest(modelID: modelID, files: singleFileLayout)
            .write(to: manifestURL(in: temp.url))

        #expect(
            !SnapshotManifest.snapshotComplete(
                forModelID: modelID,
                in: directory,
                manifestAt: manifestURL(in: temp.url)
            )
        )
    }

    @Test("a multi-shard layout with one shard missing is incomplete")
    func missingShardIsIncomplete() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotManifestTests")
        defer { temp.remove() }
        let directory = try makeSnapshotDirectory(in: temp.url)
        try touch(
            multiShardLayout.filter { $0 != "model-00002-of-00002.safetensors" },
            in: directory
        )
        try SnapshotManifest(modelID: modelID, files: multiShardLayout)
            .write(to: manifestURL(in: temp.url))

        #expect(
            !SnapshotManifest.snapshotComplete(
                forModelID: modelID,
                in: directory,
                manifestAt: manifestURL(in: temp.url)
            )
        )
    }

    /// An interrupted first download: everything still lives in the Hub's
    /// `.cache` staging as resumable `*.incomplete` partials, nothing is
    /// committed at the manifest's paths. Staging never counts.
    @Test("a staging-only directory with nothing committed is incomplete")
    func stagingOnlyIsIncomplete() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotManifestTests")
        defer { temp.remove() }
        let directory = try makeSnapshotDirectory(in: temp.url)
        try touch(
            singleFileLayout.map { ".cache/huggingface/download/\($0).abc123.incomplete" },
            in: directory
        )
        try SnapshotManifest(modelID: modelID, files: singleFileLayout)
            .write(to: manifestURL(in: temp.url))

        #expect(
            !SnapshotManifest.snapshotComplete(
                forModelID: modelID,
                in: directory,
                manifestAt: manifestURL(in: temp.url)
            )
        )
    }

    // MARK: - The shipped bug, dead

    /// The exact failure the manifest rule kills: the real summary repo's
    /// sharding index references BOTH the downloaded weight file AND a vision
    /// sidecar the download globs deliberately exclude. The old index-derived
    /// rule read this COMPLETE snapshot as forever-incomplete; under the
    /// manifest rule the index is recorded and never parsed, so the snapshot is
    /// complete without the sidecar ever existing.
    @Test("the real repo inventory is complete without the excluded vision sidecar")
    func realInventoryCompleteWithoutVisionSidecar() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotManifestTests")
        defer { temp.remove() }
        let directory = try makeSnapshotDirectory(in: temp.url)

        // The inventory the globs actually fetch, minus the index written
        // explicitly below with its real weight_map shape.
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
            .write(to: manifestURL(in: temp.url))

        // Complete — and provably WITHOUT the sidecar the index references.
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appending(path: "optiq/optiq_vision.safetensors").path
            )
        )
        #expect(
            SnapshotManifest.snapshotComplete(
                forModelID: modelID,
                in: directory,
                manifestAt: manifestURL(in: temp.url)
            )
        )
    }

    // MARK: - No manifest, no completeness claim (fail-safe direction)

    /// A complete-looking directory without a manifest reads incomplete — the
    /// accepted trade-off for snapshots that predate the manifest mechanism:
    /// the next online pass no-ops per committed file and records the first
    /// manifest.
    @Test("an absent manifest reads incomplete even with every file on disk")
    func manifestAbsentIsIncomplete() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotManifestTests")
        defer { temp.remove() }
        let directory = try makeSnapshotDirectory(in: temp.url)
        try touch(singleFileLayout, in: directory)

        #expect(
            !SnapshotManifest.snapshotComplete(
                forModelID: modelID,
                in: directory,
                manifestAt: manifestURL(in: temp.url)
            )
        )
    }

    @Test("a corrupted manifest reads incomplete and never throws")
    func corruptedManifestIsIncomplete() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotManifestTests")
        defer { temp.remove() }
        let directory = try makeSnapshotDirectory(in: temp.url)
        try touch(singleFileLayout, in: directory)
        // Not JSON at all — a torn write or bit rot must degrade to the resume
        // path, never to a crash or a false "ready".
        try Data("{not json ⚠︎".utf8).write(to: manifestURL(in: temp.url))

        #expect(
            !SnapshotManifest.snapshotComplete(
                forModelID: modelID,
                in: directory,
                manifestAt: manifestURL(in: temp.url)
            )
        )
    }

    /// Model-id scoping: after a model swap the retired model's manifest is a
    /// stale record that must read as "no manifest" for the new model — even
    /// when the file names overlap exactly.
    @Test("a manifest written for a different model id reads incomplete")
    func foreignModelManifestIsIncomplete() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotManifestTests")
        defer { temp.remove() }
        let directory = try makeSnapshotDirectory(in: temp.url)
        try touch(singleFileLayout, in: directory)
        try SnapshotManifest(modelID: "test-org/retired-model", files: singleFileLayout)
            .write(to: manifestURL(in: temp.url))

        #expect(
            !SnapshotManifest.snapshotComplete(
                forModelID: modelID,
                in: directory,
                manifestAt: manifestURL(in: temp.url)
            )
        )
    }

    /// "Every file of zero files is on disk" is vacuously true — and a false
    /// "ready" over an empty record is exactly the prohibited direction, so an
    /// empty file set must read incomplete no matter what is on disk.
    @Test("a manifest with an empty file set reads incomplete")
    func emptyFileSetIsIncomplete() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotManifestTests")
        defer { temp.remove() }
        let directory = try makeSnapshotDirectory(in: temp.url)
        try touch(singleFileLayout, in: directory)
        try SnapshotManifest(modelID: modelID, files: [])
            .write(to: manifestURL(in: temp.url))

        #expect(
            !SnapshotManifest.snapshotComplete(
                forModelID: modelID,
                in: directory,
                manifestAt: manifestURL(in: temp.url)
            )
        )
    }

    // MARK: - The record itself

    /// The record round-trips losslessly, an overwrite yields exactly the new
    /// record (each download supersedes the last — no merging), and the atomic
    /// write leaves no temp litter next to the manifest.
    @Test("a manifest write round-trips, overwrites cleanly, and leaves no litter")
    func manifestWriteRoundTrips() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotManifestTests")
        defer { temp.remove() }
        let url = manifestURL(in: temp.url)

        let first = SnapshotManifest(modelID: modelID, files: multiShardLayout)
        try first.write(to: url)
        #expect(SnapshotManifest.read(from: url) == first)

        let second = SnapshotManifest(modelID: "test-org/next-model", files: singleFileLayout)
        try second.write(to: url)
        #expect(SnapshotManifest.read(from: url) == second)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        #expect(siblings == [url.lastPathComponent])
    }
}
