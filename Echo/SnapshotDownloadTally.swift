//
//  SnapshotDownloadTally.swift
//  Echo
//
//  The byte budget of a model snapshot download, and the running tally that
//  projects it into the single fraction ∈ [0, 1] every progress consumer
//  already speaks (ADR-007).
//
//  This is the piece that makes the bar honest. The Hub client's own fraction
//  counts FILES (`Progress(totalUnitCount: filenames.count)`), so for the
//  summary model — 7 configs totalling 19 MB plus one 3.27 GB weight file —
//  the first 0.6% of the bytes filled 87.5% of the bar and the remaining 99.4%
//  had to fit in the last eighth. Weighting each file by the size the repo
//  reports for it replaces that with a number that means what it says, and
//  answers ADR-007's open follow-up (resolve the total from repo metadata at
//  download time) with the metadata the transfer already has to fetch.
//
//  Split by transport, because the two halves know their progress with
//  different precision: the weight files ride Echo's own resumable transfer
//  and report exact bytes on disk (ResumableFileDownload), while the small
//  configs stay with HubApi.snapshot and can only report files-finished. The
//  coarse half is deliberately confined to its own byte slice — 0.6% of the
//  bar for this model — so the imprecision can never again be visible as a
//  jump to 87.5%.
//

import Foundation

/// How many bytes each transport owes, resolved from repo metadata.
struct SnapshotDownloadBudget: Equatable {

    /// Total size of the files HubApi.snapshot fetches (configs, tokenizer).
    let configBytes: Int64

    /// Total size of the files Echo transfers itself (the weights).
    let weightBytes: Int64

    var totalBytes: Int64 { configBytes + weightBytes }

    /// The overall fraction, weighted by bytes. `configFraction` is the coarse
    /// files-finished ratio of the config slice; `weightBytesOnDisk` is exact.
    /// Clamped through `ModelDownloadProgress` so the one clamp in the codebase
    /// stays the one clamp, and so a coarse or replayed input can't push the
    /// bar past full.
    func fraction(configFraction: Double, weightBytesOnDisk: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        let configDone = Double(configBytes) * ModelDownloadProgress(fraction: configFraction).fraction
        let weightsDone = Double(min(max(weightBytesOnDisk, 0), weightBytes))
        return ModelDownloadProgress(fraction: (configDone + weightsDone) / Double(totalBytes)).fraction
    }
}

/// The running total behind a snapshot download's progress callbacks.
///
/// Lock-guarded and `Sendable` because the two transports report from different
/// places: HubApi's snapshot handler and URLSession's delegate queue, while the
/// stall watchdog samples the result from its own task.
///
/// Monotonic by construction: bytes already committed by an earlier run (or an
/// earlier file in this run) are counted from the start and never re-counted,
/// so a resumed download picks the bar up where it left off instead of
/// restarting at zero.
final class SnapshotDownloadTally: @unchecked Sendable {

    private let lock = NSLock()
    private let budget: SnapshotDownloadBudget
    private var configFraction: Double
    private var committedWeightBytes: Int64
    private var inFlightWeightBytes: Int64 = 0

    /// - Parameters:
    ///   - committedWeightBytes: weight bytes already committed on disk before
    ///     this attempt — what makes a resume continue rather than restart.
    ///   - configFraction: 1 when the config files are known to be on disk
    ///     already; the snapshot pass re-reports it either way.
    init(
        budget: SnapshotDownloadBudget,
        committedWeightBytes: Int64 = 0,
        configFraction: Double = 0
    ) {
        self.budget = budget
        self.committedWeightBytes = committedWeightBytes
        self.configFraction = configFraction
    }

    /// The overall fraction right now.
    var fraction: Double {
        lock.lock()
        defer { lock.unlock() }
        return currentFraction()
    }

    /// Records the config transport's files-finished ratio; returns the overall
    /// fraction. Never moves backwards: HubApi re-reports 0 at the start of a
    /// retried pass, and the bar must not drop.
    @discardableResult
    func noteConfigFraction(_ value: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        configFraction = max(configFraction, value)
        return currentFraction()
    }

    /// Records the byte count on disk for the weight file currently in flight;
    /// returns the overall fraction.
    @discardableResult
    func noteWeightBytes(_ bytesOnDisk: Int64) -> Double {
        lock.lock()
        defer { lock.unlock() }
        inFlightWeightBytes = max(inFlightWeightBytes, bytesOnDisk)
        return currentFraction()
    }

    /// Rolls a finished weight file into the committed total so the next file
    /// in a sharded snapshot starts counting from zero without losing it.
    @discardableResult
    func commitWeightFile(bytes: Int64) -> Double {
        lock.lock()
        defer { lock.unlock() }
        committedWeightBytes += bytes
        inFlightWeightBytes = 0
        return currentFraction()
    }

    private func currentFraction() -> Double {
        budget.fraction(
            configFraction: configFraction,
            weightBytesOnDisk: committedWeightBytes + inFlightWeightBytes
        )
    }
}
