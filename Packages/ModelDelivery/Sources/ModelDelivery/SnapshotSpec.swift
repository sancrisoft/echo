//
//  SnapshotSpec.swift
//  ModelDelivery
//
//  What one model's snapshot is, as far as delivery is concerned: which repo,
//  which files ride which transport, and what the two bookkeeping files beside
//  the models tree are called.
//
//  This package deliberately holds no model identity of its own. The PoC had
//  the Qwen repo id, its globs and its manifest filename spread across the
//  summary model's manager, which is why nothing else could reuse the
//  transport. Here the owner of a model (Summarization, Transcription) passes
//  one of these and the delivery machinery stays model-agnostic.
//
//  The two file names are inputs rather than derived strings because v1 and v2
//  share a data folder (ADR-005): an existing install already has
//  `summary-model-manifest.json` and a `summary-model-download/` beside its
//  models tree, and a v2 that invented new names would orphan both and force a
//  needless re-verification pass.
//

import Foundation

public struct SnapshotSpec: Equatable, Sendable {

    /// The Hugging Face repo id, e.g. `org/model`.
    public let repoID: String

    /// The files this package transfers itself: the ones big enough that the
    /// Hub client's broken progress reporting turns into a guaranteed false
    /// stall, and the ones worth resuming byte-exactly (see
    /// `ResumableFileDownload`). Globs rather than filenames, so a resharded
    /// repo publishing `model-00001-of-0000N.safetensors` keeps matching.
    public let weightGlobs: [String]

    /// Everything else — configs and tokenizer — which stays with the Hub
    /// snapshot pass. Small enough that its files-finished progress is accurate
    /// to within its own slice of the bytes, and the Hub keeps owning their
    /// etag and metadata bookkeeping.
    public let configGlobs: [String]

    /// The completeness manifest, beside the models tree rather than inside
    /// the snapshot directory. See `SnapshotManifest`.
    public let manifestFileName: String

    /// Directory beside the models tree where in-flight `.partial` transfers
    /// accumulate. Outside the repo directory on purpose: the Hub's offline
    /// pass validates every file it finds there and would reject a partial it
    /// never wrote.
    public let partialDirectoryName: String

    public init(
        repoID: String,
        weightGlobs: [String],
        configGlobs: [String],
        manifestFileName: String,
        partialDirectoryName: String
    ) {
        self.repoID = repoID
        self.weightGlobs = weightGlobs
        self.configGlobs = configGlobs
        self.manifestFileName = manifestFileName
        self.partialDirectoryName = partialDirectoryName
    }

    /// Every file the snapshot is made of, and so what the completeness
    /// manifest records. The two transports' globs must stay disjoint — for the
    /// summary model `model.safetensors.index.json` is a config, not a weight.
    public var downloadGlobs: [String] { weightGlobs + configGlobs }
}
