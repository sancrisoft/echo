//
//  SnapshotDownloadTally.swift
//  ModelDelivery
//
//  The byte budget of a model snapshot download, and the running tally that
//  projects it into the single fraction ∈ [0, 1] every progress consumer
//  already speaks.
//
//  This is the piece that makes the bar honest. The Hub client's own fraction
//  counts FILES (`Progress(totalUnitCount: filenames.count)`), so for the
//  summary model — 7 configs totalling 19 MB plus one 3.27 GB weight file —
//  the first 0.6% of the bytes filled 87.5% of the bar and the remaining 99.4%
//  had to fit in the last eighth. Weighting each file by the size the repo
//  reports for it replaces that with a number that means what it says.
//
//  Split by transport, because the two halves know their progress with
//  different precision: the weight files ride this package's own resumable
//  transfer and report exact bytes on disk (`ResumableFileDownload`), while
//  the small configs stay with the Hub snapshot pass and can only report
//  files-finished. The coarse half is deliberately confined to its own byte
//  slice — 0.6% of the bar for this model — so the imprecision can never again
//  be visible as a jump to 87.5%.
//

import Foundation
import Synchronization

/// How many bytes each transport owes, resolved from repo metadata.
public struct SnapshotDownloadBudget: Equatable, Sendable {

    /// Total size of the files the Hub snapshot pass fetches (configs, tokenizer).
    public let configBytes: Int64

    /// Total size of the files this package transfers itself (the weights).
    public let weightBytes: Int64

    public init(configBytes: Int64, weightBytes: Int64) {
        self.configBytes = configBytes
        self.weightBytes = weightBytes
    }

    public var totalBytes: Int64 { configBytes + weightBytes }

    /// The overall fraction, weighted by bytes. `configFraction` is the coarse
    /// files-finished ratio of the config slice; `weightBytesOnDisk` is exact.
    /// Clamped through `DownloadProgress` so the one clamp in the codebase
    /// stays the one clamp, and so a coarse or replayed input cannot push the
    /// bar past full.
    public func fraction(configFraction: Double, weightBytesOnDisk: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        let configDone = Double(configBytes) * DownloadProgress(fraction: configFraction).fraction
        let weightsDone = Double(min(max(weightBytesOnDisk, 0), weightBytes))
        return DownloadProgress(fraction: (configDone + weightsDone) / Double(totalBytes)).fraction
    }
}

/// The running total behind a snapshot download's progress callbacks.
///
/// Lock-guarded because the two transports report from different places: the
/// Hub snapshot handler and URLSession's delegate queue, while the stall
/// watchdog samples the result from its own task. A `Mutex` rather than an
/// actor because every caller is a synchronous progress callback that cannot
/// await, and the critical section is pure arithmetic.
///
/// Monotonic by construction: bytes already committed by an earlier run (or an
/// earlier file in this run) are counted from the start and never re-counted,
/// so a resumed download picks the bar up where it left off instead of
/// restarting at zero.
public final class SnapshotDownloadTally: Sendable {

    private struct State {
        var configFraction: Double
        var committedWeightBytes: Int64
        var inFlightWeightBytes: Int64 = 0
    }

    private let budget: SnapshotDownloadBudget
    private let state: Mutex<State>

    /// - Parameters:
    ///   - committedWeightBytes: weight bytes already committed on disk before
    ///     this attempt — what makes a resume continue rather than restart.
    ///   - configFraction: 1 when the config files are known to be on disk
    ///     already; the snapshot pass re-reports it either way.
    public init(
        budget: SnapshotDownloadBudget,
        committedWeightBytes: Int64 = 0,
        configFraction: Double = 0
    ) {
        self.budget = budget
        self.state = Mutex(
            State(configFraction: configFraction, committedWeightBytes: committedWeightBytes)
        )
    }

    /// The overall fraction right now.
    public var fraction: Double {
        state.withLock { fraction(of: $0) }
    }

    /// Records the config transport's files-finished ratio; returns the overall
    /// fraction. Never moves backwards: the Hub pass re-reports 0 at the start
    /// of a retried pass, and the bar must not drop.
    @discardableResult
    public func noteConfigFraction(_ value: Double) -> Double {
        state.withLock {
            $0.configFraction = max($0.configFraction, value)
            return fraction(of: $0)
        }
    }

    /// Records the byte count on disk for the weight file currently in flight;
    /// returns the overall fraction.
    @discardableResult
    public func noteWeightBytes(_ bytesOnDisk: Int64) -> Double {
        state.withLock {
            $0.inFlightWeightBytes = max($0.inFlightWeightBytes, bytesOnDisk)
            return fraction(of: $0)
        }
    }

    /// Rolls a finished weight file into the committed total so the next file
    /// in a sharded snapshot starts counting from zero without losing it.
    @discardableResult
    public func commitWeightFile(bytes: Int64) -> Double {
        state.withLock {
            $0.committedWeightBytes += bytes
            $0.inFlightWeightBytes = 0
            return fraction(of: $0)
        }
    }

    /// Pure arithmetic over a snapshot of the state, so it is safe to call
    /// from inside the lock.
    private func fraction(of state: State) -> Double {
        budget.fraction(
            configFraction: state.configFraction,
            weightBytesOnDisk: state.committedWeightBytes + state.inFlightWeightBytes
        )
    }
}
