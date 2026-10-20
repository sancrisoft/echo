//
//  MeetingLibrarySearchTests.swift
//  MeetingsTests
//
//  Search through the library's public face: it reads nothing until it is
//  first asked for, then reads every meeting through the store and keeps
//  current as the library changes — a rename, a trip to Trash, a meeting
//  deleted for good. Fixtures are saved through the store into a temp root.
//

import EchoCore
import EchoCoreTestSupport
import Foundation
import Meetings
import Testing

@Suite("MeetingLibrary search")
@MainActor
struct MeetingLibrarySearchTests {

    private func withTempLibrary(_ body: (MeetingLibrary, MeetingStore) async throws -> Void) async throws {
        let temp = try TemporaryDirectory(prefix: "MeetingLibrarySearchTests")
        defer { temp.remove() }
        let store = MeetingStore(rootDirectory: temp.path("Meetings"))
        try await body(MeetingLibrary(store: store, modelsDirectory: nil), store)
    }

    @discardableResult
    private func save(
        _ title: String, saying text: String, summary: String? = nil, in store: MeetingStore
    ) async throws -> UUID {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let meta = MeetingMeta(
            id: UUID(), title: title, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60), segmentCount: 0,
            hasSummary: false)
        let segments = [TranscriptSegment(channel: .system, text: text, start: 0, end: 4)]
        try await store.save(MeetingRecord(meta: meta, segments: segments, summaryMarkdown: summary))
        return meta.id
    }

    private func titles(_ library: MeetingLibrary, _ text: String) async -> [String] {
        await library.search(MeetingSearchQuery.parse(text)).map(\.meta.title)
    }

    @Test("nothing is read until search is asked for, then what was said is found")
    func readsOnFirstAsk() async throws {
        try await withTempLibrary { library, store in
            try await save("Weekly", saying: "The pineapple budget is approved.", in: store)
            await library.refresh()
            #expect(await titles(library, "pineapple").isEmpty)
            #expect(!library.isReadingForSearch)

            let before = library.searchRevision
            await library.prepareSearch()
            #expect(await titles(library, "pineapple") == ["Weekly"])
            #expect(library.searchRevision > before)
            #expect(!library.isReadingForSearch)
        }
    }

    @Test("the summary on disk is read too")
    func readsSummaries() async throws {
        try await withTempLibrary { library, store in
            try await save(
                "Board", saying: "Hello everyone.", summary: "### Decisions\n- Ship the kiwi release", in: store)
            await library.refresh()
            await library.prepareSearch()
            #expect(await titles(library, "kiwi") == ["Board"])
        }
    }

    @Test("a rename is searchable as soon as the library has re-read")
    func followsRenames() async throws {
        try await withTempLibrary { library, store in
            let id = try await save("Kickoff", saying: "Hello everyone.", in: store)
            await library.refresh()
            await library.prepareSearch()
            await library.rename(id, to: "Retrospective")
            await library.prepareSearch()
            #expect(await titles(library, "kickoff").isEmpty)
            #expect(await titles(library, "retrospective") == ["Retrospective"])
        }
    }

    @Test("a trashed meeting answers only in:trash, and one deleted for good not at all")
    func followsTrash() async throws {
        try await withTempLibrary { library, store in
            let id = try await save("Weekly", saying: "The mango plan.", in: store)
            await library.refresh()
            await library.prepareSearch()
            await library.trash(id)
            await library.prepareSearch()
            #expect(await titles(library, "mango").isEmpty)
            #expect(await titles(library, "mango in:trash") == ["Weekly"])

            await library.deletePermanently(id)
            await library.prepareSearch()
            #expect(await titles(library, "mango in:trash").isEmpty)
        }
    }
}
