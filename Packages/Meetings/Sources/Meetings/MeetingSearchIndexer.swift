//
//  MeetingSearchIndexer.swift
//  Meetings
//
//  Reads meetings into the search index off the main actor, and answers
//  queries there. What it read each meeting with is its header: a different
//  header — a rename, a new summary, a transcript run again, a trip to Trash —
//  means the words may have changed, and the meeting is read again. Reading
//  goes through `MeetingStore`, the one reader of `Meetings/`.
//

import EchoCore
import Foundation

actor MeetingSearchIndexer {
    private let store: MeetingStore
    private var index = MeetingSearchIndex()
    /// The header each meeting was read with.
    private var readWith: [UUID: MeetingMeta] = [:]

    init(store: MeetingStore) {
        self.store = store
    }

    /// Forgets the meetings `metas` no longer holds, and says which of the
    /// others need reading, again or for the first time.
    func reconcile(with metas: [MeetingMeta]) -> (forgot: Bool, toRead: [MeetingMeta]) {
        let wanted = Set(metas.map(\.id))
        let gone = readWith.keys.filter { !wanted.contains($0) }
        if !gone.isEmpty {
            index.remove(gone)
            for id in gone { readWith[id] = nil }
        }
        return (!gone.isEmpty, metas.filter { readWith[$0.id] != $0 })
    }

    /// Reads these meetings' words into the index. A meeting whose files
    /// cannot be read is still found by its header.
    func read(_ metas: [MeetingMeta]) async {
        var documents: [SearchDocument] = []
        for meta in metas {
            do {
                let record = try await store.loadRecord(meta.id)
                documents.append(
                    SearchDocument(meta: meta, segments: record.segments, summaryMarkdown: record.summaryMarkdown))
            } catch {
                ErrorTrace.record(
                    "Reading a meeting for search failed",
                    error: error,
                    category: "MeetingSearch",
                    metadata: ["meetingID": meta.id.uuidString]
                )
                documents.append(SearchDocument(meta: meta, segments: [], summaryMarkdown: nil))
            }
            readWith[meta.id] = meta
        }
        index.insert(documents)
    }

    func search(_ query: MeetingSearchQuery) -> [MeetingSearchHit] {
        index.search(query)
    }
}
