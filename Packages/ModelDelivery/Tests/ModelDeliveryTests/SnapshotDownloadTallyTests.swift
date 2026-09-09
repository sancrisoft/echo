//
//  SnapshotDownloadTallyTests.swift
//  ModelDeliveryTests
//
//  The byte-weighted progress projection, including the regression it exists
//  for: with a files-finished fraction, the summary snapshot's 19 MB of configs
//  filled 87.5% of the bar (7 of 8 files) while the 3.27 GB of weights fit in
//  the last eighth.
//
//  And the arithmetic behind the second one: the opening balance and the commit
//  count the same bytes, so a weight file already on disk may enter the tally
//  exactly once. Counted twice on a sharded repo, the fraction saturates while
//  the transfer has barely begun — and the fraction is also the stall
//  watchdog's heartbeat, so a saturated bar stops beating and a healthy
//  download is cancelled as `downloadStalled`.
//

import ModelDelivery
import Testing

@Suite("Snapshot download tally")
struct SnapshotDownloadTallyTests {

    /// The real shape of the summary model's snapshot.
    private static let summaryBudget = SnapshotDownloadBudget(
        configBytes: 20_173_663,  // 7 configs + tokenizer
        weightBytes: 3_269_669_552  // model.safetensors
    )

    // MARK: - The regression

    /// Every config file on disk and not one byte of weights is 0.6% of the
    /// download — not 87.5%.
    @Test("the config files alone are a sliver of the bar")
    func configFilesAloneAreASliverOfTheBar() {
        let fraction = Self.summaryBudget.fraction(configFraction: 1, weightBytesOnDisk: 0)
        #expect(fraction < 0.01)
        #expect(DownloadProgress(fraction: fraction).percent == 0)
    }

    /// Half the weight bytes reads as roughly half the download, which is what
    /// a user watching a 3.3 GB transfer needs the number to mean.
    @Test("half the weights is about half the download")
    func halfTheWeightsIsAboutHalfTheDownload() {
        let fraction = Self.summaryBudget.fraction(
            configFraction: 1,
            weightBytesOnDisk: Self.summaryBudget.weightBytes / 2
        )
        #expect(DownloadProgress(fraction: fraction).percent == 50)
    }

    @Test("every byte is exactly complete")
    func everyByteIsExactlyComplete() {
        let fraction = Self.summaryBudget.fraction(
            configFraction: 1,
            weightBytesOnDisk: Self.summaryBudget.weightBytes
        )
        #expect(DownloadProgress(fraction: fraction).isDownloadComplete)
    }

    // MARK: - Bounds

    @Test("a budget of nothing reports zero rather than NaN")
    func aBudgetOfNothingReportsZeroRatherThanNaN() {
        let empty = SnapshotDownloadBudget(configBytes: 0, weightBytes: 0)
        #expect(empty.fraction(configFraction: 1, weightBytesOnDisk: 100) == 0)
    }

    /// Overshooting inputs (a replayed fraction, a partial larger than the
    /// published size) can't push the bar past full.
    @Test("overshooting inputs clamp to complete")
    func overshootingInputsClampToComplete() {
        let budget = SnapshotDownloadBudget(configBytes: 100, weightBytes: 900)
        #expect(budget.fraction(configFraction: 4, weightBytesOnDisk: 5_000) == 1)
        #expect(budget.fraction(configFraction: -1, weightBytesOnDisk: -50) == 0)
    }

    // MARK: - The running tally

    @Test("the tally counts both transports")
    func tallyCountsBothTransports() {
        let budget = SnapshotDownloadBudget(configBytes: 100, weightBytes: 900)
        let tally = SnapshotDownloadTally(budget: budget)

        #expect(tally.fraction == 0)
        #expect(tally.noteConfigFraction(1) == 0.1)
        #expect(tally.noteWeightBytes(450) == 0.55)
        #expect(tally.commitWeightFile(bytes: 450) == 0.55)
    }

    /// A resumed attempt starts the bar where the last one stopped — the
    /// behavior that stops a stall retry from looking like a restart.
    @Test("already committed bytes count from the start")
    func alreadyCommittedBytesCountFromTheStart() {
        let budget = SnapshotDownloadBudget(configBytes: 100, weightBytes: 900)
        let tally = SnapshotDownloadTally(budget: budget, committedWeightBytes: 300, configFraction: 1)

        #expect(tally.fraction == 0.4)
    }

    /// The host re-reports 0 at the start of a retried snapshot pass, and a
    /// re-opened transfer re-reports its offset; neither may drag the bar back.
    @Test("progress never moves backwards")
    func progressNeverMovesBackwards() {
        let budget = SnapshotDownloadBudget(configBytes: 100, weightBytes: 900)
        let tally = SnapshotDownloadTally(budget: budget)

        _ = tally.noteConfigFraction(1)
        _ = tally.noteWeightBytes(600)
        #expect(tally.noteConfigFraction(0) == 0.7)
        #expect(tally.noteWeightBytes(10) == 0.7)
    }

    /// A sharded snapshot: each finished file rolls into the committed total so
    /// the next one starts counting from zero without losing it.
    @Test("shards accumulate")
    func shardsAccumulate() {
        let budget = SnapshotDownloadBudget(configBytes: 0, weightBytes: 1_000)
        let tally = SnapshotDownloadTally(budget: budget)

        _ = tally.noteWeightBytes(400)
        #expect(tally.commitWeightFile(bytes: 400) == 0.4)
        _ = tally.noteWeightBytes(600)  // second shard, from zero
        #expect(tally.commitWeightFile(bytes: 600) == 1)
    }

    // MARK: - Bytes counted once

    /// The arithmetic under a shipped defect: a weight file already on disk at
    /// its published size is in the opening balance, and committing it again
    /// counts the same bytes a second time.
    ///
    /// 0.4 is what a skipped shard must leave the bar at. 0.8 is the bug —
    /// on this two-shard budget the released build showed 80% for a download
    /// that had transferred nothing, and the second shard then pushed it to a
    /// saturated 1.0 with gigabytes still to fetch. A saturated fraction is a
    /// heartbeat that never advances, so the stall watchdog cancelled the
    /// healthy transfer and it died as `downloadStalled`.
    @Test("committing a file the opening balance already counted counts it twice")
    func committingAnAlreadyCountedFileCountsItTwice() {
        // Two shards, 400 and 600 bytes, against no configs.
        let budget = SnapshotDownloadBudget(configBytes: 0, weightBytes: 1_000)
        // Shard A is already on disk, so it opens the tally's balance.
        let tally = SnapshotDownloadTally(budget: budget, committedWeightBytes: 400)

        // Skipping it reports where the bar stands and adds nothing to it, no
        // matter how often the skip branch is taken.
        #expect(tally.fraction == 0.4)
        #expect(tally.fraction == 0.4)

        // The bug: shard A's 400 bytes, counted a second time.
        #expect(tally.commitWeightFile(bytes: 400) == 0.8)
    }

    /// The corrected sequence end to end on a sharded resume: shard A is
    /// skipped, shard B streams and commits, and the bar reaches full on shard
    /// B's last byte — not one step earlier. Asserted step by step, because a
    /// fraction that saturates early is precisely what freezes the heartbeat.
    @Test("a sharded resume reaches full only on the last byte")
    func shardedResumeReachesFullOnlyOnTheLastByte() {
        let budget = SnapshotDownloadBudget(configBytes: 0, weightBytes: 1_000)
        let tally = SnapshotDownloadTally(budget: budget, committedWeightBytes: 400)

        // Shard A: on disk, skipped, already counted.
        #expect(tally.fraction == 0.4)
        #expect(tally.fraction < 1)

        // Shard B streams in.
        #expect(tally.noteWeightBytes(200) == 0.6)
        #expect(tally.noteWeightBytes(400) == 0.8)
        #expect(tally.noteWeightBytes(599) < 1)

        // Full arrives with shard B's last byte, and survives its commit.
        #expect(tally.noteWeightBytes(600) == 1)
        #expect(tally.commitWeightFile(bytes: 600) == 1)
    }
}
