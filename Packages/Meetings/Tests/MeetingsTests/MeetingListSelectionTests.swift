import Foundation
import Meetings
import Testing

@Suite("MeetingListSelection")
struct MeetingListSelectionTests {

    private let ids = (0..<4).map { _ in UUID() }

    @Test("↓ from nothing selects the first row, ↑ from nothing selects the last")
    func firstArrowLandsSomewhere() {
        #expect(MeetingListSelection.destination(from: nil, move: .down, in: ids) == ids[0])
        #expect(MeetingListSelection.destination(from: nil, move: .up, in: ids) == ids[3])
    }

    @Test("Arrows step one row at a time in the visible order")
    func arrowsStep() {
        #expect(MeetingListSelection.destination(from: ids[1], move: .down, in: ids) == ids[2])
        #expect(MeetingListSelection.destination(from: ids[1], move: .up, in: ids) == ids[0])
    }

    @Test("The selection holds at both ends instead of wrapping")
    func noWrap() {
        #expect(MeetingListSelection.destination(from: ids[3], move: .down, in: ids) == ids[3])
        #expect(MeetingListSelection.destination(from: ids[0], move: .up, in: ids) == ids[0])
    }

    @Test("Home / End jump to the ends from anywhere")
    func homeEnd() {
        #expect(MeetingListSelection.destination(from: ids[2], move: .first, in: ids) == ids[0])
        #expect(MeetingListSelection.destination(from: ids[1], move: .last, in: ids) == ids[3])
    }

    @Test("A selection the filter has hidden is treated as no selection")
    func hiddenSelection() {
        let hidden = UUID()
        #expect(MeetingListSelection.destination(from: hidden, move: .down, in: ids) == ids[0])
    }

    @Test("An empty list has nowhere to move")
    func emptyList() {
        #expect(MeetingListSelection.destination(from: nil, move: .down, in: []) == nil)
        #expect(MeetingListSelection.destination(from: ids[0], move: .last, in: []) == nil)
    }

    @Test("A still-visible selection survives; a filtered-away one is dropped")
    func reconcile() {
        #expect(MeetingListSelection.reconcile(ids[1], with: ids) == ids[1])
        #expect(MeetingListSelection.reconcile(ids[1], with: [ids[0], ids[2]]) == nil)
        #expect(MeetingListSelection.reconcile(nil, with: ids) == nil)
    }

    @Test("Trashing hands the selection to the row that slides up, then the previous, then nothing")
    func afterRemoving() {
        #expect(MeetingListSelection.selectionAfterRemoving(ids[1], from: ids) == ids[2])
        #expect(MeetingListSelection.selectionAfterRemoving(ids[3], from: ids) == ids[2])
        #expect(MeetingListSelection.selectionAfterRemoving(ids[0], from: [ids[0]]) == nil)
        #expect(MeetingListSelection.selectionAfterRemoving(UUID(), from: ids) == nil)
    }
}
