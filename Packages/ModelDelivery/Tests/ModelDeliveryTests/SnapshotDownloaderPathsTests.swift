//
//  SnapshotDownloaderPathsTests.swift
//  ModelDeliveryTests
//
//  Everything the snapshot downloader can answer with the network unplugged:
//  where the three paths land, whether a snapshot is already on disk, and
//  whether an interrupted transfer left something resumable. `download` itself
//  is not exercised here — it makes real requests, and none of these
//  guarantees need one.
//
//  The paths half is ported from the PoC's SummaryModelPathsTests, with its
//  one assertion deliberately dropped and inverted: the PoC asserted that the
//  models directory EXISTS after the path accessor is read, because reading the
//  accessor created it. v2's `DataRoot` creates nothing — the package that owns
//  a subtree creates it when it writes — so the ported test asserts the
//  opposite, that deriving every path creates nothing at all. The rest is
//  coverage the PoC never had: the negative on where the manifest and the
//  partial directory sit, and the two on-disk questions.
//

import EchoCoreTestSupport
import Foundation
import Hub
import ModelDelivery
import Testing

@Suite("Snapshot downloader paths")
struct SnapshotDownloaderPathsTests {

    /// A stand-in for a real model's spec. The two bookkeeping names are the
    /// ones an existing v1 install already has beside its models tree — v2
    /// shares the data folder, so it inherits them rather than inventing new
    /// ones.
    private static let spec = SnapshotSpec(
        repoID: "test-org/test-model",
        weightGlobs: ["model*.safetensors"],
        configGlobs: ["*.json", "tokenizer.json"],
        manifestFileName: "summary-model-manifest.json",
        partialDirectoryName: "summary-model-download"
    )

    private static let snapshotFiles = [
        "config.json",
        "tokenizer.json",
        "model.safetensors",
    ]

    private func makeDownloader(modelsRoot: URL) -> SnapshotDownloader {
        SnapshotDownloader(modelsRoot: modelsRoot, spec: Self.spec)
    }

    /// Writes small stand-in files at repo-relative paths under `directory`.
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

    // MARK: - Where the paths land

    @Test("the snapshot directory is the Hub's models/<org>/<repo> layout under the models root")
    func snapshotDirectoryIsTheHubLayout() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotDownloaderPathsTests")
        defer { temp.remove() }
        let modelsRoot = temp.path("Models")
        let downloader = makeDownloader(modelsRoot: modelsRoot)

        // The literal contract…
        #expect(
            downloader.snapshotDirectory.path
                == modelsRoot.appending(path: "models/\(Self.spec.repoID)").path
        )
        // …and the same path the Hub client itself derives, so a file this
        // package writes is a file the Hub's own passes will find.
        let hubLocation = HubApi(downloadBase: modelsRoot, cache: nil)
            .localRepoLocation(HubApi.Repo(id: Self.spec.repoID))
        #expect(downloader.snapshotDirectory == hubLocation)
    }

    /// The defended behavior: the Hub's offline snapshot pass validates every
    /// repo file matching the download globs and fails on one without a
    /// `.metadata` sidecar. A manifest or a `.partial` planted inside the repo
    /// directory would poison offline resume, so both live beside the models
    /// tree. Asserted as a negative, because that is the failure mode.
    @Test("the manifest and the partial directory sit beside the models tree, never inside the snapshot")
    func bookkeepingSitsOutsideTheSnapshotDirectory() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotDownloaderPathsTests")
        defer { temp.remove() }
        let modelsRoot = temp.path("Models")
        let downloader = makeDownloader(modelsRoot: modelsRoot)

        #expect(downloader.manifestFileURL.deletingLastPathComponent().path == modelsRoot.path)
        #expect(downloader.partialDownloadDirectory.deletingLastPathComponent().path == modelsRoot.path)
        #expect(downloader.manifestFileURL.lastPathComponent == Self.spec.manifestFileName)
        #expect(downloader.partialDownloadDirectory.lastPathComponent == Self.spec.partialDirectoryName)

        let snapshotPrefix = downloader.snapshotDirectory.path + "/"
        #expect(!downloader.manifestFileURL.path.hasPrefix(snapshotPrefix))
        #expect(!downloader.partialDownloadDirectory.path.hasPrefix(snapshotPrefix))
    }

    /// The inverted PoC assertion. Reading every path — and asking both on-disk
    /// questions — must leave the models root exactly as it was: an empty
    /// directory that does not even exist yet.
    @Test("deriving the paths and asking what is on disk creates nothing")
    func derivingThePathsCreatesNothing() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotDownloaderPathsTests")
        defer { temp.remove() }
        let modelsRoot = temp.path("Models")
        let downloader = makeDownloader(modelsRoot: modelsRoot)

        _ = downloader.snapshotDirectory
        _ = downloader.manifestFileURL
        _ = downloader.partialDownloadDirectory
        _ = downloader.snapshotExists()
        _ = downloader.partialDownloadBytes()

        #expect(!FileManager.default.fileExists(atPath: modelsRoot.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).isEmpty)
    }

    // MARK: - What is already on disk

    @Test("an empty models root holds no snapshot and nothing resumable")
    func emptyModelsRootHoldsNothing() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotDownloaderPathsTests")
        defer { temp.remove() }
        let downloader = makeDownloader(modelsRoot: temp.path("Models"))

        #expect(downloader.snapshotExists() == false)
        #expect(downloader.partialDownloadBytes() == nil)
    }

    @Test("a manifest and every file it records make the snapshot exist")
    func manifestAndFilesMakeTheSnapshotExist() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotDownloaderPathsTests")
        defer { temp.remove() }
        let downloader = makeDownloader(modelsRoot: temp.path("Models"))
        try touch(Self.snapshotFiles, in: downloader.snapshotDirectory)

        // Incomplete until the record exists…
        #expect(downloader.snapshotExists() == false)

        try SnapshotManifest(modelID: Self.spec.repoID, files: Self.snapshotFiles)
            .write(to: downloader.manifestFileURL)

        #expect(downloader.snapshotExists() == true)
    }

    /// Model-id scoping, through the downloader's own seam: after a model swap
    /// the previous model's record is beside the same models tree and must read
    /// as no record at all.
    @Test("a manifest naming a different repo leaves the snapshot unfound")
    func foreignManifestLeavesTheSnapshotUnfound() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotDownloaderPathsTests")
        defer { temp.remove() }
        let downloader = makeDownloader(modelsRoot: temp.path("Models"))
        try touch(Self.snapshotFiles, in: downloader.snapshotDirectory)
        try SnapshotManifest(modelID: "test-org/retired-model", files: Self.snapshotFiles)
            .write(to: downloader.manifestFileURL)

        #expect(downloader.snapshotExists() == false)
    }

    // MARK: - Is there something resumable

    /// A complete snapshot has nothing to resume, so the signal is nil even
    /// though there are gigabytes under the snapshot directory — the caller
    /// reads this as a boolean, and "there is a partial" must be false the
    /// moment the download is done.
    @Test("a complete snapshot reports no partial bytes")
    func completeSnapshotReportsNoPartialBytes() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotDownloaderPathsTests")
        defer { temp.remove() }
        let downloader = makeDownloader(modelsRoot: temp.path("Models"))
        try touch(Self.snapshotFiles, in: downloader.snapshotDirectory)
        try SnapshotManifest(modelID: Self.spec.repoID, files: Self.snapshotFiles)
            .write(to: downloader.manifestFileURL)

        #expect(downloader.partialDownloadBytes() == nil)
    }

    @Test("an interrupted transfer's partials report their bytes")
    func interruptedTransferReportsItsBytes() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotDownloaderPathsTests")
        defer { temp.remove() }
        let downloader = makeDownloader(modelsRoot: temp.path("Models"))
        let partial = downloader.partialDownloadDirectory
            .appending(path: "model.safetensors.partial", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: downloader.partialDownloadDirectory,
            withIntermediateDirectories: true
        )
        let bytes = Data(repeating: 0x7f, count: 4_096)
        try bytes.write(to: partial)

        #expect(downloader.partialDownloadBytes() == Int64(bytes.count))
    }

    /// The Hub's own resumable staging lives INSIDE the snapshot directory,
    /// this package's `.partial` files beside it, and an interrupted download
    /// can hold both. The signal covers the two together.
    @Test("staging inside the snapshot and partials beside it are counted together")
    func stagingAndPartialsAreCountedTogether() throws {
        let temp = try TemporaryDirectory(prefix: "SnapshotDownloaderPathsTests")
        defer { temp.remove() }
        let downloader = makeDownloader(modelsRoot: temp.path("Models"))
        let staged = Data(repeating: 0x01, count: 1_024)
        let partial = Data(repeating: 0x02, count: 2_048)

        let stagedURL = downloader.snapshotDirectory
            .appending(path: ".cache/huggingface/download/model.safetensors.abc123.incomplete")
        try FileManager.default.createDirectory(
            at: stagedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try staged.write(to: stagedURL)

        let partialURL = downloader.partialDownloadDirectory
            .appending(path: "model.safetensors.partial", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: downloader.partialDownloadDirectory,
            withIntermediateDirectories: true
        )
        try partial.write(to: partialURL)

        #expect(downloader.partialDownloadBytes() == Int64(staged.count + partial.count))
    }
}
