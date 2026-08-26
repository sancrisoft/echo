//
//  MeetingListNavigation.swift
//  Echo
//
//  The meetings list's selection rules, kept out of the view so they can be
//  exercised without a window. The list is date-grouped and search-filtered,
//  so "the next row" is the next id in the *visible, flattened* order — never
//  the next id inside a section, and never a meeting the current filter hides.
//

import Foundation

/// Where a keyboard command moves the meetings list's selection.
enum MeetingListMove: Equatable, Sendable {
    case up
    case down
    case first
    case last
}

enum MeetingListNavigation {

    /// The id the selection lands on after `move`, or `nil` when nothing is
    /// visible.
    ///
    /// With nothing selected, ↓ takes the first row and ↑ the last, so the
    /// first arrow press always lands somewhere (Finder's behaviour). A
    /// selection that is no longer in `ids` — the search field just filtered
    /// it away — counts as no selection. At either end the selection holds
    /// rather than wrapping: arrowing past the last row in a long list and
    /// silently landing back at the top is disorienting.
    static func destination(from selection: UUID?, move: MeetingListMove, in ids: [UUID]) -> UUID? {
        guard let first = ids.first, let last = ids.last else { return nil }
        switch move {
        case .first: return first
        case .last: return last
        case .up, .down:
            guard let current = selection, let index = ids.firstIndex(of: current) else {
                return move == .down ? first : last
            }
            let next = move == .down ? index + 1 : index - 1
            guard ids.indices.contains(next) else { return current }
            return ids[next]
        }
    }

    /// The selection to keep once the visible set changes (a search keystroke,
    /// a new meeting, a trashed one). Anything still visible survives;
    /// anything that isn't is dropped, so the list never paints a highlight
    /// for a row that is no longer there and the next arrow press starts from
    /// a clean slate.
    static func reconcile(_ selection: UUID?, with ids: [UUID]) -> UUID? {
        guard let selection, ids.contains(selection) else { return nil }
        return selection
    }

    /// Where the selection goes after `id` leaves the list (moved to Trash).
    /// `ids` is the order *before* the removal. The row that slides up into
    /// the gap takes the selection, so a run of deletes keeps working from the
    /// keyboard; deleting the last row falls back to the new last row, and
    /// deleting the only row clears the selection.
    static func selectionAfterRemoving(_ id: UUID, from ids: [UUID]) -> UUID? {
        guard let index = ids.firstIndex(of: id) else {
            return nil
        }
        if ids.indices.contains(index + 1) { return ids[index + 1] }
        if ids.indices.contains(index - 1) { return ids[index - 1] }
        return nil
    }
}
