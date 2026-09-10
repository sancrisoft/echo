//
//  SummaryModelPathsTests.swift
//  SummarizationTests
//
//  What delivery is told about THIS model, and why none of it is free to
//  change.
//
//  The path arithmetic itself — `models/<org>/<repo>` under the models root,
//  the manifest and the partial directory beside the models tree, and that
//  deriving any of them creates nothing — belongs to the type that owns it and
//  is asserted in `ModelDelivery`'s `SnapshotDownloaderPathsTests`. Repeating
//  it here would pin the same arithmetic twice and say nothing about the
//  summary model. What is specific to this model is the spec: the repo id, the
//  two bookkeeping file names an existing v1 install already has beside its
//  models tree (ADR-005: v1 and v2 share the data folder, so inventing names
//  would orphan both and force a needless re-verification of 3.3 GB), and the
//  disjointness the two transports require.
//
//  The PoC's version of this file was near-tautological — it rebuilt the path
//  by hand and asserted the result had the prefix it had just written —
//  because the snapshot directory was private. It is reachable now, so this
//  asserts the contract instead of the arithmetic.
//

import Foundation
import ModelDelivery
import Testing

@testable import Summarization

@Suite("The summary model's snapshot spec")
struct SummaryModelPathsTests {

    /// Does `name` match one of `globs`, with the shell semantics the two
    /// transports select files by? `fnmatch` rather than a hand-rolled
    /// matcher: the point is the globs' meaning, not a reimplementation of it.
    private func matches(_ name: String, _ globs: [String]) -> Bool {
        globs.contains { fnmatch($0, name, 0) == 0 }
    }

    @Test("the spec names the one model Echo summarizes with")
    func specNamesTheModel() {
        #expect(SummaryModel.snapshotSpec.repoID == "mlx-community/Qwen3.5-4B-OptiQ-4bit")
        // One identity, not two: the id delivery resolves paths from is the id
        // the app displays a model by.
        #expect(SummaryModel.snapshotSpec.repoID == SummaryModel.modelID)
    }

    /// An on-disk contract with v1, not a naming preference. Changing either
    /// string orphans an existing install's bookkeeping.
    @Test("the bookkeeping file names are v1's, verbatim")
    func bookkeepingNamesAreInheritedFromV1() {
        #expect(SummaryModel.snapshotSpec.manifestFileName == "summary-model-manifest.json")
        #expect(SummaryModel.snapshotSpec.partialDirectoryName == "summary-model-download")
    }

    /// The two transports must not both claim a file: one counted by the tally
    /// and committed by the other is counted twice, which saturates the
    /// fraction that doubles as the stall heartbeat and fails a healthy
    /// download.
    @Test("the weight and config globs are disjoint")
    func weightAndConfigGlobsAreDisjoint() {
        let spec = SummaryModel.snapshotSpec
        #expect(Set(spec.weightGlobs).isDisjoint(with: Set(spec.configGlobs)))

        // The case that made this a rule: the sharding index is a config, not a
        // weight, despite the name it wears.
        #expect(matches("model.safetensors.index.json", spec.configGlobs))
        #expect(!matches("model.safetensors.index.json", spec.weightGlobs))

        // And the weights the text path does transfer ride only the weight
        // transport.
        #expect(matches("model.safetensors", spec.weightGlobs))
        #expect(!matches("model.safetensors", spec.configGlobs))
        #expect(matches("model-00001-of-00002.safetensors", spec.weightGlobs))
    }

    /// The repo carries bf16 sidecars under `optiq/` that the text path
    /// neither downloads nor loads. Asserted as a negative, because that is
    /// the failure mode: a glob that swept them in would add gigabytes to
    /// every download for files nothing reads.
    @Test("neither glob matches the optiq sidecars the text path never loads")
    func globsExcludeTheOptiqSidecars() {
        let spec = SummaryModel.snapshotSpec
        for sidecar in ["mtp.safetensors", "optiq_vision.safetensors"] {
            #expect(!matches(sidecar, spec.weightGlobs))
            #expect(!matches(sidecar, spec.configGlobs))
        }
    }
}
