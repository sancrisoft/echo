//
//  WeightDispositionTests.swift
//  ModelDeliveryTests
//
//  The one decision the two halves of `transferSnapshot` have to agree on:
//  whether a weight file already sitting at its destination counts as
//  transferred. The tally's opening balance sums the files the verdict calls
//  committed; the transfer loop skips those same files and reports the
//  fraction without committing them again.
//
//  They once disagreed, and the file was counted twice. On a sharded repo that
//  saturated the fraction while the transfer had barely begun — and the
//  fraction is also the stall watchdog's heartbeat, so a saturated bar stopped
//  beating, a healthy multi-GB download was cancelled as silent, and three
//  attempts later the user was told it had stalled.
//
//  Two layers, the shape `ResumableFileDownload.resumeDecision` uses next door:
//  the verdict itself, one named case per test, and then the invariant it
//  exists for — seed the tally from it, walk a sharded resume through it, and
//  check at every step that the bar equals the bytes genuinely on disk, which
//  is what "counted exactly once" means. Pure arithmetic: no network, no disk.
//

import Testing

@testable import ModelDelivery

@Suite("Weight disposition")
struct WeightDispositionTests {

    // MARK: - The verdict

    @Test("a file at its published size is already committed")
    func fileAtItsPublishedSizeIsAlreadyCommitted() {
        #expect(
            SnapshotDownloader.disposition(onDiskBytes: 1_000, expectedBytes: 1_000)
                == .alreadyCommitted(bytes: 1_000)
        )
    }

    @Test("nothing at the destination is transferred")
    func nothingAtTheDestinationIsTransferred() {
        #expect(SnapshotDownloader.disposition(onDiskBytes: 0, expectedBytes: 1_000) == .transfer)
    }

    @Test("a file short of its published size is transferred")
    func fileShortOfItsPublishedSizeIsTransferred() {
        #expect(SnapshotDownloader.disposition(onDiskBytes: 400, expectedBytes: 1_000) == .transfer)
    }

    /// A destination larger than the published size is a file that outlived the
    /// model it belonged to. Re-fetching costs bandwidth; blessing it would hand
    /// the runtime a corrupt tensor file and put its bytes in the bar as if they
    /// were the model's.
    @Test("a file larger than its published size is never trusted")
    func fileLargerThanItsPublishedSizeIsNeverTrusted() {
        #expect(SnapshotDownloader.disposition(onDiskBytes: 1_400, expectedBytes: 1_000) == .transfer)
    }

    /// Without a published size there is nothing to compare against, so no file
    /// can be declared complete — whatever is on disk. The transfer's own
    /// completeness check owns the verdict from there.
    @Test("a file whose repo published no size is never already committed")
    func fileWithoutAPublishedSizeIsNeverAlreadyCommitted() {
        #expect(SnapshotDownloader.disposition(onDiskBytes: 0, expectedBytes: nil) == .transfer)
        #expect(SnapshotDownloader.disposition(onDiskBytes: 1_000, expectedBytes: nil) == .transfer)
    }

    /// The degenerate row, pinned deliberately rather than left to be
    /// rediscovered: a repo that publishes a zero-byte weight file reads as
    /// already committed, and an absent file reads the same way, because a byte
    /// count cannot tell "empty" from "not there".
    ///
    /// Harmless where it lands. There is nothing to transfer either way; the
    /// bytes it contributes to the opening balance are zero, so the two call
    /// sites still agree; and a file that is genuinely missing is caught by
    /// `SnapshotManifest.allFilesCommitted`, which asks the file system whether
    /// the file exists rather than how big it is.
    @Test("a published size of zero reads as already committed")
    func publishedSizeOfZeroReadsAsAlreadyCommitted() {
        #expect(SnapshotDownloader.disposition(onDiskBytes: 0, expectedBytes: 0) == .alreadyCommitted(bytes: 0))
    }

    // MARK: - The invariant the verdict exists for

    /// One weight file of a sharded repo: the size the repo publishes for it,
    /// and what is actually sitting at its destination.
    private struct Shard {
        let published: Int64
        let onDisk: Int64
    }

    /// A sharded repo mid-resume: one shard complete, one untouched, one left
    /// part-way, and one left larger than its published size.
    private static let shards = [
        Shard(published: 400, onDisk: 400),
        Shard(published: 600, onDisk: 0),
        Shard(published: 200, onDisk: 50),
        Shard(published: 300, onDisk: 999),
    ]

    private static func disposition(of shard: Shard) -> SnapshotDownloader.WeightDisposition {
        SnapshotDownloader.disposition(onDiskBytes: shard.onDisk, expectedBytes: shard.published)
    }

    /// The defect stated as an invariant: because both call sites read the same
    /// verdict, every published byte enters the tally exactly once. Driven the
    /// way `transferSnapshot` drives it — seed from `.alreadyCommitted`, skip
    /// those shards without committing, transfer the rest — and checked at every
    /// step against an independent count of the bytes genuinely on disk.
    ///
    /// Counting one shard twice breaks the next assertion here, instead of
    /// surfacing on a user's machine as a stalled download three attempts later.
    @Test("the opening balance and the skip branch count every byte exactly once")
    func openingBalanceAndSkipBranchCountEveryByteOnce() {
        let published = Self.shards.reduce(Int64(0)) { $0 + $1.published }
        let budget = SnapshotDownloadBudget(configBytes: 0, weightBytes: published)

        // The opening balance, exactly as `transferSnapshot` computes it.
        let seed = Self.shards.reduce(Int64(0)) { total, shard in
            switch Self.disposition(of: shard) {
            case .alreadyCommitted(let bytes): return total + bytes
            case .transfer: return total
            }
        }
        // The fixture has to exercise both verdicts, or the invariant is vacuous.
        #expect(seed == 400)

        let tally = SnapshotDownloadTally(budget: budget, committedWeightBytes: seed)
        // The independent truth: bytes genuinely on disk for this snapshot.
        // Every fraction the tally reports has to be the projection of THIS
        // number, which is exactly what "counted once" means.
        var accounted = seed
        #expect(tally.fraction == budget.fraction(configFraction: 0, weightBytesOnDisk: accounted))

        var skipped = 0
        for shard in Self.shards {
            switch Self.disposition(of: shard) {
            case .alreadyCommitted:
                // The skip branch: report where the bar stands, commit nothing.
                skipped += 1
                #expect(tally.fraction == budget.fraction(configFraction: 0, weightBytesOnDisk: accounted))
            case .transfer:
                for streamed in [shard.published / 4, shard.published / 2, shard.published] {
                    #expect(
                        tally.noteWeightBytes(streamed)
                            == budget.fraction(configFraction: 0, weightBytesOnDisk: accounted + streamed)
                    )
                }
                accounted += shard.published
                #expect(
                    tally.commitWeightFile(bytes: shard.published)
                        == budget.fraction(configFraction: 0, weightBytesOnDisk: accounted)
                )
            }
        }

        #expect(skipped == 1)
        #expect(accounted == published)
        #expect(tally.fraction == 1)
    }
}
