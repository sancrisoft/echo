//
//  FinalPassModelSnapshotTests.swift
//  EchoTests
//
//  SP-005 S5: manifest-derived completeness for the final-pass model's
//  snapshot (ADR-012 register applied to the WhisperKit repo layout — no
//  hardcoded four-file list, the pre-ADR-012 `cachedModelFolder` mistake).
//  Table tests over synthetic temp-dir layouts, mirroring
//  SnapshotCompletenessTests: complete; one file missing; size mismatch;
//  manifest record absent; staging-only — reading "incomplete" in every
//  doubtful direction. Real-FS temp URLs; the real models root is never
//  touched.
//

import Foundation
import Testing
@testable import Echo

@Suite("Final-pass model snapshot completeness (ADR-012)")
struct FinalPassModelSnapshotTests {

    private let variantFolder = "openai_whisper-large-v3_947MB"

    /// The 947 MB variant's real shape in miniature: compiled `.mlmodelc`
    /// bundles (directories of files) plus top-level configs — exactly the
    /// layout a fixed flat file list can't describe, which is why the
    /// manifest records repo-relative paths.
    private var layout: [String] {
        [
            "\(variantFolder)/config.json",
            "\(variantFolder)/generation_config.json",
            "\(variantFolder)/MelSpectrogram.mlmodelc/coremldata.bin",
            "\(variantFolder)/AudioEncoder.mlmodelc/weights/weight.bin",
            "\(variantFolder)/AudioEncoder.mlmodelc/model.mil",
            "\(variantFolder)/TextDecoder.mlmodelc/weights/weight.bin",
            "\(variantFolder)/TextDecoder.mlmodelc/model.mil",
        ]
    }

    // MARK: - Fixture helpers (throwaway real-FS roots)

    /// A fresh throwaway models root: the WhisperKit repo directory lives at
    /// models/argmaxinc/whisperkit-coreml inside it and the manifest beside
    /// the models tree, mirroring the production layout.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "FinalPassModelSnapshotTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRepoDirectory(in root: URL) throws -> URL {
        let directory = root.appending(
            path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func manifestURL(in root: URL) -> URL {
        root.appending(path: "final-pass-model-manifest.json", directoryHint: .notDirectory)
    }

    /// Creates stand-in files at the given repo-relative paths, each with a
    /// distinct size (its index in the list plus one bytes) so size-mismatch
    /// rows are meaningful.
    private func touch(_ relativePaths: [String], in directory: URL) throws {
        for (index, path) in relativePaths.enumerated() {
            let url = directory.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0x55, count: index + 1).write(to: url)
        }
    }

    /// Records the given paths at their actual on-disk sizes — the
    /// downloader's verify-then-record step in miniature.
    private func records(
        for relativePaths: [String],
        in directory: URL
    ) throws -> [FinalPassSnapshotManifest.FileRecord] {
        try relativePaths.map { path in
            let url = directory.appending(path: path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return .init(path: path, size: Int64(size))
        }
    }

    // MARK: - Complete

    @Test("every manifest file on disk at its recorded size is complete")
    func completeSnapshotReadsComplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeRepoDirectory(in: root)
        try touch(layout, in: repo)
        try FinalPassSnapshotManifest(
            variantFolder: variantFolder,
            files: records(for: layout, in: repo)
        ).write(to: manifestURL(in: root))

        #expect(FinalPassSnapshotManifest.snapshotComplete(
            forVariantFolder: variantFolder, in: repo, manifestAt: manifestURL(in: root)
        ))
    }

    // MARK: - Partial must never read as ready

    @Test("one file missing reads incomplete")
    func missingFileReadsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeRepoDirectory(in: root)
        try touch(layout, in: repo)
        let manifest = try FinalPassSnapshotManifest(
            variantFolder: variantFolder,
            files: records(for: layout, in: repo)
        )
        try manifest.write(to: manifestURL(in: root))
        try FileManager.default.removeItem(
            at: repo.appending(path: "\(variantFolder)/TextDecoder.mlmodelc/weights/weight.bin")
        )

        #expect(!FinalPassSnapshotManifest.snapshotComplete(
            forVariantFolder: variantFolder, in: repo, manifestAt: manifestURL(in: root)
        ))
    }

    @Test("a file at the wrong size reads incomplete")
    func sizeMismatchReadsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeRepoDirectory(in: root)
        try touch(layout, in: repo)
        try FinalPassSnapshotManifest(
            variantFolder: variantFolder,
            files: records(for: layout, in: repo)
        ).write(to: manifestURL(in: root))
        // Truncate one weight blob AFTER the manifest recorded its real size
        // — the "present but torn" case a bare existence check waves through.
        try Data().write(
            to: repo.appending(path: "\(variantFolder)/AudioEncoder.mlmodelc/weights/weight.bin")
        )

        #expect(!FinalPassSnapshotManifest.snapshotComplete(
            forVariantFolder: variantFolder, in: repo, manifestAt: manifestURL(in: root)
        ))
    }

    /// An interrupted first download: everything still lives in the Hub's
    /// `.cache` staging as resumable `*.incomplete` partials, nothing
    /// committed at the manifest's paths. Staging never counts.
    @Test("staging-only directory (.cache partials, nothing committed) reads incomplete")
    func stagingOnlyReadsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeRepoDirectory(in: root)
        try touch(
            layout.map { ".cache/huggingface/download/\($0).abc123.incomplete" },
            in: repo
        )
        // A manifest exists (say, from an earlier complete download the user
        // then deleted files from) — files still decide.
        try FinalPassSnapshotManifest(
            variantFolder: variantFolder,
            files: layout.enumerated().map { .init(path: $1, size: Int64($0 + 1)) }
        ).write(to: manifestURL(in: root))

        #expect(!FinalPassSnapshotManifest.snapshotComplete(
            forVariantFolder: variantFolder, in: repo, manifestAt: manifestURL(in: root)
        ))
    }

    // MARK: - No manifest, no completeness claim (fail-safe direction)

    /// Files present but no manifest record → incomplete: the re-verify path,
    /// where the next online pass no-ops per committed file and records the
    /// first manifest (ADR-012's accepted migration trade-off).
    @Test("manifest record absent reads incomplete even with every file on disk")
    func manifestAbsentReadsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeRepoDirectory(in: root)
        try touch(layout, in: repo)

        #expect(!FinalPassSnapshotManifest.snapshotComplete(
            forVariantFolder: variantFolder, in: repo, manifestAt: manifestURL(in: root)
        ))
    }

    @Test("corrupted manifest reads incomplete and never throws")
    func corruptedManifestReadsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeRepoDirectory(in: root)
        try touch(layout, in: repo)
        try Data("{not json ⚠︎".utf8).write(to: manifestURL(in: root))

        #expect(!FinalPassSnapshotManifest.snapshotComplete(
            forVariantFolder: variantFolder, in: repo, manifestAt: manifestURL(in: root)
        ))
    }

    /// Variant scoping: a record written for another variant folder (a
    /// retired checkpoint's) must read as "no manifest", never vouch for
    /// this snapshot.
    @Test("manifest written for a different variant reads incomplete")
    func foreignVariantManifestReadsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeRepoDirectory(in: root)
        try touch(layout, in: repo)
        try FinalPassSnapshotManifest(
            variantFolder: "openai_whisper-large-v3-v20240930_626MB",
            files: records(for: layout, in: repo)
        ).write(to: manifestURL(in: root))

        #expect(!FinalPassSnapshotManifest.snapshotComplete(
            forVariantFolder: variantFolder, in: repo, manifestAt: manifestURL(in: root)
        ))
    }

    /// "Every file of zero files is committed" is vacuously true — an empty
    /// record must read incomplete no matter what's on disk.
    @Test("manifest with an empty file set reads incomplete")
    func emptyFileSetReadsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeRepoDirectory(in: root)
        try touch(layout, in: repo)
        try FinalPassSnapshotManifest(variantFolder: variantFolder, files: [])
            .write(to: manifestURL(in: root))

        #expect(!FinalPassSnapshotManifest.snapshotComplete(
            forVariantFolder: variantFolder, in: repo, manifestAt: manifestURL(in: root)
        ))
    }

    // MARK: - The record itself

    @Test("manifest write round-trips and an overwrite yields exactly the new record")
    func manifestWriteRoundTrips() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = manifestURL(in: root)

        let first = FinalPassSnapshotManifest(
            variantFolder: variantFolder,
            files: [.init(path: "\(variantFolder)/config.json", size: 42)]
        )
        try first.write(to: url)
        #expect(FinalPassSnapshotManifest.read(from: url) == first)

        let second = FinalPassSnapshotManifest(
            variantFolder: "openai_whisper-next_1GB",
            files: [.init(path: "openai_whisper-next_1GB/config.json", size: 7)]
        )
        try second.write(to: url)
        #expect(FinalPassSnapshotManifest.read(from: url) == second)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(siblings == [url.lastPathComponent])
    }
}
