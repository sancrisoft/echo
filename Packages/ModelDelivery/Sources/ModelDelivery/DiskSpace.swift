//
//  DiskSpace.swift
//  ModelDelivery
//
//  The free-disk floor a snapshot download refuses to start below. Checked
//  before the first byte rather than discovered halfway through several GB,
//  where the failure would be a truncated file and a wasted hour.
//

import Foundation

public enum DiskSpace {

    /// Free-disk floor for starting a download. Measured: the retired 12B
    /// model's 15 GB floor gave its ~8.9 GB snapshot roughly 1.7x headroom
    /// (the transfer plus the Hub's own staging); this is the same ratio
    /// applied to the ~3.3 GB download that replaced it. Rescaled
    /// deliberately — a floor still sized for the 12B would block the
    /// migration on exactly the full disks it is about to relieve.
    public static let defaultFloor: Int64 = 6 * 1_000_000_000

    /// Space the volume holding `url` will give up for an important download,
    /// or nil when no ancestor of `url` exists to ask.
    ///
    /// `volumeAvailableCapacityForImportantUsage` rather than the raw free
    /// space: it is what the system will actually reclaim (purgeable caches
    /// included) for a user-initiated download.
    ///
    /// Walks up to the nearest existing ancestor because the answer is a
    /// property of the volume, not the path — and the models directory does
    /// not exist until the first download writes to it. The PoC could ask the
    /// directory directly only because reading its path accessor created it;
    /// v2's `DataRoot` creates nothing, so asking a missing directory would
    /// return nil and silently disable the floor.
    public static func freeBytes(at url: URL) -> Int64? {
        var candidate = url.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: candidate.path) {
                let values = try? candidate.resourceValues(
                    forKeys: [.volumeAvailableCapacityForImportantUsageKey]
                )
                return values?.volumeAvailableCapacityForImportantUsage
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent != candidate else { return nil }
            candidate = parent
        }
    }

    /// Throws when the volume holding `url` is below `floor`.
    ///
    /// Fails open when the volume cannot report its capacity: a download that
    /// might not fit is still worth attempting, while refusing to start
    /// because a filesystem answered oddly would strand the user with no model
    /// and no explanation.
    public static func check(at url: URL, floor: Int64 = defaultFloor) throws {
        guard let free = freeBytes(at: url) else { return }
        if free < floor {
            throw ModelDeliveryError.insufficientDiskSpace(freeBytes: free, requiredBytes: floor)
        }
    }
}
