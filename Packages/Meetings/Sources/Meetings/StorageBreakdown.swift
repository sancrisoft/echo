//
//  StorageBreakdown.swift
//  Meetings
//
//  What the library occupies on disk, split the way the settings page shows
//  it. Meetings and recordings are disjoint (a folder's preserved `audio-*`
//  bytes are subtracted from its meeting bytes), so the rows sum to the real
//  footprint. One measurement feeds both the sidebar footer and the settings
//  page; there is no second way to count.
//

import EchoCore
import Foundation

public struct StorageBreakdown: Equatable, Sendable {
    /// Non-trashed meeting folders, minus their preserved `audio-*` bytes.
    public var meetingsBytes: Int64 = 0
    /// Preserved `audio-*` bytes across non-trashed folders.
    public var recordingsBytes: Int64 = 0
    /// Non-trashed meetings holding a preserved recording.
    public var recordingsCount: Int = 0
    /// Trashed meeting folders, whole.
    public var trashBytes: Int64 = 0
    /// The models directory under the data root.
    public var modelsBytes: Int64 = 0

    public init(
        meetingsBytes: Int64 = 0,
        recordingsBytes: Int64 = 0,
        recordingsCount: Int = 0,
        trashBytes: Int64 = 0,
        modelsBytes: Int64 = 0
    ) {
        self.meetingsBytes = meetingsBytes
        self.recordingsBytes = recordingsBytes
        self.recordingsCount = recordingsCount
        self.trashBytes = trashBytes
        self.modelsBytes = modelsBytes
    }

    /// Everything the user's meetings occupy: meetings, recordings and trash.
    /// The models are infrastructure, not user data, and stay out of it.
    public var libraryBytes: Int64 { meetingsBytes + recordingsBytes + trashBytes }

    /// The pure aggregation, parameterized so tests run it on synthetic temp
    /// trees: meeting folders split into "meeting data" vs "saved recording"
    /// by the preserved names, trash counted whole, models counted whole.
    public static func measure(
        meetingsRoot: URL,
        nonTrashedIDs: [UUID],
        trashedIDs: [UUID],
        modelsDirectory: URL?
    ) -> StorageBreakdown {
        var breakdown = StorageBreakdown()
        for id in nonTrashedIDs {
            let folder = meetingsRoot.appending(path: id.uuidString, directoryHint: .isDirectory)
            let whole = directorySize(at: folder)
            var audio: Int64 = 0
            for channel in AudioChannel.allCases {
                let url = folder.appending(
                    path: MeetingStore.preservedAudioFileName(for: channel), directoryHint: .notDirectory)
                audio += fileSize(at: url)
            }
            if audio > 0 { breakdown.recordingsCount += 1 }
            breakdown.recordingsBytes += audio
            breakdown.meetingsBytes += max(0, whole - audio)
        }
        for id in trashedIDs {
            breakdown.trashBytes += directorySize(
                at: meetingsRoot.appending(path: id.uuidString, directoryHint: .isDirectory))
        }
        if let modelsDirectory {
            breakdown.modelsBytes = directorySize(at: modelsDirectory)
        }
        return breakdown
    }

    private static let sizeKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: sizeKeys)
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    static func directorySize(at url: URL) -> Int64 {
        let keys = sizeKeys.union([.isRegularFileKey])
        guard
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
