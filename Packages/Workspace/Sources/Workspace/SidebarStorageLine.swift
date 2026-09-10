//
//  SidebarStorageLine.swift
//  Workspace
//
//  The last line of the sidebar: what the library occupies, and where. The
//  whole point of it is to tell someone whether they need to free space, so it
//  says nothing until the real measurement of the real files has landed — an
//  estimate that drifts from the disk is worse than no line at all — and it
//  counts the user's own data only. The models are infrastructure; the
//  settings screen accounts for them separately.
//

import Foundation
import Meetings

enum SidebarStorageLine {

    /// The line, or `nil` when there is nothing true to say: no measurement
    /// yet, or an empty library, which would otherwise read as "Zero KB".
    static func text(for storage: StorageBreakdown?) -> String? {
        guard let storage, storage.libraryBytes > 0 else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: storage.libraryBytes, countStyle: .file)
        return "\(size) · on this Mac"
    }
}
