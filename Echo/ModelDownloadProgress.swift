//
//  ModelDownloadProgress.swift
//  Echo
//
//  The single, overflow-proof projection of a model download's progress
//  (ADR-007). Progress is defined by ONE source — the downloader's own
//  repo-file-size fraction ∈ [0, 1] (the same `snapshotProgress.fractionCompleted`
//  the active download reports) — and every user-facing figure derives from it,
//  so `downloaded ≤ total` and `percent ≤ 100` are arithmetic, not a coincidence
//  of two independent numbers. This is what makes the "8.93 GB of 8.3 GB on
//  disk" class of display (a recursive disk sum measured against a hardcoded
//  total) impossible to reintroduce.
//
//  Pure value type on purpose: no Foundation/SwiftUI dependency, unit-testable
//  in isolation (SP-003 Testing Decisions, layer 1).
//

/// Projects a raw download fraction into a bounded, display-ready form.
struct ModelDownloadProgress: Equatable {

    /// The download fraction, always within [0, 1]. Clamped on construction so
    /// no caller can push it past complete: a stall retry replaying its last
    /// reached fraction, a coarse host callback, or the old at-rest disk sum
    /// can all momentarily report a raw value outside the interval.
    let fraction: Double

    /// Clamps `rawFraction` (NaN/±∞ included) into [0, 1].
    init(fraction rawFraction: Double) {
        self.fraction = Self.bounded(rawFraction)
    }

    /// Whole-number percent for display, always in 0...100 (the clamped
    /// fraction bounds it). Truncated rather than rounded so it reads 100 only
    /// when the download is genuinely complete — 99.9% never rounds up to a
    /// "done" the files haven't reached yet.
    var percent: Int {
        Int(fraction * 100)
    }

    /// Every byte is on disk. This marks the DOWNLOAD complete — not the model
    /// usable: a distinct load/"preparing" phase still follows before "ready"
    /// (ADR-007), which is why the projection stops here and never carries a
    /// readiness claim. `percent == 100` iff this is true.
    var isDownloadComplete: Bool {
        fraction >= 1
    }

    /// A byte readout derived as `fraction × total` from this same fraction —
    /// never a recursive disk sum measured against an independent constant.
    /// Because `fraction ≤ 1`, `downloaded ≤ total` holds arithmetically; the
    /// ADR-007 follow-up (resolve `total` from repo metadata at download time)
    /// keeps this the one honest way to show "X of Y GB".
    func downloadedBytes(ofTotal total: Int64) -> Int64 {
        Int64((Double(total) * fraction).rounded())
    }

    /// NaN collapses to 0 and infinities to the nearest bound; everything else
    /// clamps to [0, 1].
    private static func bounded(_ value: Double) -> Double {
        guard value.isFinite else { return value > 0 ? 1 : 0 }
        return min(1, max(0, value))
    }
}
