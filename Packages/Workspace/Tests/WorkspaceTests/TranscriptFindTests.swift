import DesignSystem
import EchoCore
import Foundation
import SwiftUI
import Testing

@testable import Workspace

@Suite("Find in transcript")
@MainActor
struct TranscriptFindTests {

    private let turns = TranscriptUtterance.derive(from: [
        TranscriptSegment(
            channel: .system, speaker: .teammates, text: "It keeps rejecting the trades I make.", start: 862,
            end: 870),
        TranscriptSegment(
            channel: .microphone, speaker: .me, text: "So the API takes the trade, then rejects it?", start: 941,
            end: 948),
        TranscriptSegment(
            channel: .system, speaker: .teammates, text: "Déjà vu: the trade is rejected again.", start: 952,
            end: 960),
    ])

    @Test("every occurrence, in reading order, ignoring case")
    func readingOrder() {
        let matches = TranscriptFind.matches(of: "TRADE", in: turns)
        #expect(matches.map(\.turn) == [turns[0].id, turns[1].id, turns[2].id])
        let found = matches.compactMap { match in
            turns.first { $0.id == match.turn }.map { String($0.text[match.range]) }
        }
        #expect(found == ["trade", "trade", "trade"])
    }

    @Test("several occurrences in one turn are each a match, and never overlap")
    func withinATurn() {
        let matches = TranscriptFind.matches(of: "reject", in: turns)
        #expect(matches.count == 3)
        #expect(
            TranscriptFind.matches(
                of: "aa",
                in: TranscriptUtterance.derive(from: [
                    TranscriptSegment(channel: .microphone, speaker: .me, text: "aaaa", start: 0, end: 1)
                ])
            ).count == 2)
    }

    @Test("accents are ignored, as macOS's own find ignores them")
    func accents() {
        #expect(TranscriptFind.matches(of: "deja", in: turns).count == 1)
    }

    @Test("an empty query, or one of only spaces, finds nothing")
    func nothingToFind() {
        #expect(TranscriptFind.matches(of: "", in: turns).isEmpty)
        #expect(TranscriptFind.matches(of: "   ", in: turns).isEmpty)
    }

    @Test("⌘G and ⇧⌘G step through the matches and wrap at either end")
    func stepping() {
        #expect(TranscriptFind.step(from: nil, by: 1, count: 3) == 0)
        #expect(TranscriptFind.step(from: nil, by: -1, count: 3) == 2)
        #expect(TranscriptFind.step(from: 0, by: 1, count: 3) == 1)
        #expect(TranscriptFind.step(from: 2, by: 1, count: 3) == 0)
        #expect(TranscriptFind.step(from: 0, by: -1, count: 3) == 2)
        #expect(TranscriptFind.step(from: 1, by: 1, count: 0) == nil)
    }

    @Test("the field counts the matches and says which one the user is on")
    func counter() {
        #expect(TranscriptFind.counter(current: 2, count: 12) == "3 of 12")
        #expect(TranscriptFind.counter(current: nil, count: 0) == "0 of 0")
    }

    @Test("each turn gets its own matches, and only one of all of them is current")
    func highlightsByTurn() {
        let matches = TranscriptFind.matches(of: "reject", in: turns)
        let highlights = TranscriptView.highlights(matches, current: 1)
        #expect(highlights[turns[0].id]?.map(\.isCurrent) == [false])
        #expect(highlights[turns[1].id]?.map(\.isCurrent) == [true])
        #expect(highlights[turns[2].id]?.map(\.isCurrent) == [false])
    }

    // MARK: For the eye

    private func render(current: Int?, _ scheme: ColorScheme) throws -> CGImage {
        let renderer = ImageRenderer(
            content: TranscriptView(
                turns: turns, matches: TranscriptFind.matches(of: "trade", in: turns), current: current
            )
            .frame(width: 520)
            .padding(EchoSpacing.l)
            .background(EchoColor.windowBackground)
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        return try #require(renderer.cgImage, "the transcript rendered nothing")
    }

    @Test("the current match is drawn apart from the others, in both appearances")
    func currentStandsOut() throws {
        EchoFont.registerBundledTypefaces()
        for (appearance, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let first = try render(current: 0, scheme)
            let second = try render(current: 1, scheme)
            #expect(first.dataProvider?.data != second.dataProvider?.data, "no current match in \(appearance)")
            Attachment.record(first, named: "transcript-find-\(appearance).png")
        }
    }
}
