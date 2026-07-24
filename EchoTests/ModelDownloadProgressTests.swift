//
//  ModelDownloadProgressTests.swift
//  EchoTests
//
//  The executable form of SP-003's "honest progress" criterion (ADR-007): a
//  raw download fraction — which a stall retry or a coarse host callback can
//  momentarily report outside [0, 1], and which the old disk-sum-vs-hardcoded
//  readout let run past the total ("8.93 GB of 8.3 GB") — projects into a
//  display form where `downloaded ≤ total` and `percent ≤ 100` hold by
//  construction, for every input.
//

import Testing
@testable import Echo

struct ModelDownloadProgressTests {

    // MARK: Clamping (tracer)

    @Test func clampsFractionIntoTheUnitInterval() {
        // In-range values pass through untouched…
        #expect(ModelDownloadProgress(fraction: 0).fraction == 0)
        #expect(ModelDownloadProgress(fraction: 0.5).fraction == 0.5)
        #expect(ModelDownloadProgress(fraction: 1).fraction == 1)
        // …and out-of-range values clamp: above complete (the 8.93/8.3 = 1.076
        // ratio) to 1, below zero to 0.
        #expect(ModelDownloadProgress(fraction: 1.076).fraction == 1)
        #expect(ModelDownloadProgress(fraction: -0.3).fraction == 0)
    }

    // MARK: Percent

    @Test(arguments: [
        (0.0, 0),
        (0.5, 50),
        (1.0, 100),
    ] as [(Double, Int)])
    func percentMirrorsTheFraction(raw: Double, expected: Int) {
        #expect(ModelDownloadProgress(fraction: raw).percent == expected)
    }

    /// The overflow the whole slice exists to kill: no raw input — however far
    /// past 1 — can print a percentage above 100, and none below 0 goes negative.
    @Test(arguments: [1.076, 1.5, 12.0, .infinity, -0.5, -100.0] as [Double])
    func percentStaysWithinZeroToHundred(raw: Double) {
        let percent = ModelDownloadProgress(fraction: raw).percent
        #expect(percent >= 0)
        #expect(percent <= 100)
    }

    // MARK: Derived byte readout

    /// Any byte readout is `fraction × total` from the SAME source, so
    /// `downloaded ≤ total` is arithmetic — the "8.93 GB of 8.3 GB" overflow is
    /// impossible even when the raw fraction arrives past 1.
    @Test(arguments: [0.0, 0.5, 1.0, 1.076, 12.0, .infinity, -0.5] as [Double])
    func derivedBytesNeverExceedTotal(raw: Double) {
        let total: Int64 = 8_300_000_000  // the summary model's ~8.3 GB nominal size
        let downloaded = ModelDownloadProgress(fraction: raw).downloadedBytes(ofTotal: total)
        #expect(downloaded >= 0)
        #expect(downloaded <= total)
    }

    @Test func derivedBytesTrackTheFraction() {
        let total: Int64 = 1_000
        #expect(ModelDownloadProgress(fraction: 0).downloadedBytes(ofTotal: total) == 0)
        #expect(ModelDownloadProgress(fraction: 0.5).downloadedBytes(ofTotal: total) == 500)
        #expect(ModelDownloadProgress(fraction: 1).downloadedBytes(ofTotal: total) == total)
    }

    // MARK: Download complete ≠ usable

    /// 100% marks the DOWNLOAD complete (files on disk) — not the model usable.
    /// A distinct load/"preparing" phase still follows before "ready" (ADR-007),
    /// so the projection carries only a download-complete signal and never
    /// asserts readiness. This is the guard against a bar that implies a model
    /// is ready while a load step remains.
    @Test func hundredPercentMeansDownloadedNotReady() {
        let complete = ModelDownloadProgress(fraction: 1)
        #expect(complete.percent == 100)
        #expect(complete.isDownloadComplete)

        // Even a raw value past 1 is still just "download complete", never more.
        #expect(ModelDownloadProgress(fraction: 1.076).isDownloadComplete)
    }

    /// The flip side: a not-quite-finished download is not complete, and its
    /// percent does not round up to a 100 the bytes haven't earned.
    @Test func nearlyCompleteIsNeitherHundredPercentNorComplete() {
        let almost = ModelDownloadProgress(fraction: 0.999)
        #expect(almost.percent == 99)
        #expect(!almost.isDownloadComplete)
    }
}
