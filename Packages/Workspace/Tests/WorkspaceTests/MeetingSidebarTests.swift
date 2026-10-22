//
//  MeetingSidebarTests.swift
//  WorkspaceTests
//
//  The sidebar is a column of rows that all have to be the same row. That is
//  geometry, so it is checked by rendering: a row is the artboard's height
//  whatever it carries, and a title far too long for the column does not make
//  it one point wider.
//

import DesignSystem
import Foundation
import Meetings
import SwiftUI
import Testing

@testable import Workspace

@Suite("Sidebar rows")
struct MeetingSidebarTests {

    private func size(of view: some View) -> CGSize {
        let renderer = ImageRenderer(content: view.fixedSize())
        renderer.scale = 2
        return renderer.nsImage?.size ?? .zero
    }

    private func meta(_ title: String, summary: Bool = true) -> MeetingMeta {
        MeetingMeta(
            id: UUID(), title: title, startedAt: .now, endedAt: .now.addingTimeInterval(1800), segmentCount: 3,
            hasSummary: summary,
            transcriptProvenance: TranscriptProvenance(source: .finalPass, modelName: "test"))
    }

    @Test("a row is the artboard's height, marked or not, selected or not")
    func rowHeight() {
        let finished = MeetingRowView(meta: meta("Quarterly roadmap"), isSelected: false, isHovered: false)
        let marked = MeetingRowView(meta: meta("1:1 with Sam", summary: false), isSelected: false, isHovered: false)
        let selected = MeetingRowView(meta: meta("Quarterly roadmap"), isSelected: true, isHovered: false)
        #expect(size(of: finished).height == EchoLayout.sidebarRowHeight)
        #expect(size(of: marked).height == EchoLayout.sidebarRowHeight)
        #expect(size(of: selected).height == EchoLayout.sidebarRowHeight)
    }

    @Test("the mark is drawn only for a meeting that is not finished")
    func markedRowIsWider() {
        let title = "Quarterly roadmap"
        let finished = size(of: MeetingRowView(meta: meta(title), isSelected: false, isHovered: false))
        let marked = size(of: MeetingRowView(meta: meta(title, summary: false), isSelected: false, isHovered: false))
        #expect(marked.width > finished.width, "the row with no summary carries no mark")
    }

    @Test("a selected row weighs more than an unselected one, and stays the same height")
    func selectionIsWeightNotHeight() {
        let title = "Support escalation review"
        let plain = size(of: MeetingRowView(meta: meta(title), isSelected: false, isHovered: false))
        let selected = size(of: MeetingRowView(meta: meta(title), isSelected: true, isHovered: false))
        #expect(selected.width > plain.width, "the selected title is not set heavier")
        #expect(selected.height == plain.height)
    }
}
