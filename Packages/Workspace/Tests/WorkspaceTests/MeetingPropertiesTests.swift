import Foundation
import Meetings
import Testing

@testable import Workspace

@Suite("The facts under a meeting's title")
struct MeetingPropertiesTests {

    private let start = Date(timeIntervalSince1970: 1_787_824_000)

    private func meta(
        minutes: Double = 58, words: Int? = 5512, capture: CaptureScopeRecord? = .app(named: "Zoom"),
        hasSummary: Bool = true
    ) -> MeetingMeta {
        MeetingMeta(
            id: UUID(), title: "GoCoInvest onboarding", startedAt: start,
            endedAt: start.addingTimeInterval(minutes * 60), segmentCount: 3, hasSummary: hasSummary,
            wordCount: words, captureScope: capture)
    }

    @Test("a complete meeting has every row, in the artboard's order")
    func everyRow() {
        let meeting = meta()
        #expect(
            MeetingProperty.rows(for: meeting) == [
                .date(start: meeting.startedAt, end: meeting.endedAt),
                .duration(58 * 60),
                .words(5512),
                .capture("Zoom only"),
                .status(.summarized),
            ])
    }

    @Test("a meeting that captured everything says so")
    func everything() {
        #expect(MeetingProperty.rows(for: meta(capture: .everything)).contains(.capture("Everything")))
    }

    @Test("a fact the meeting never kept has no row, rather than an empty one")
    func missingFacts() {
        let rows = MeetingProperty.rows(for: meta(words: nil, capture: nil))
        #expect(!rows.contains { if case .words = $0 { true } else { false } })
        #expect(!rows.contains { if case .capture = $0 { true } else { false } })
        #expect(rows.count == 3)
    }

    @Test("the status row is the meeting's status")
    func status() {
        #expect(MeetingProperty.rows(for: meta(hasSummary: false)).last == .status(.transcribed))
    }

    @Test("a duration is written to the minute, and never as nothing")
    func duration() {
        #expect(MeetingProperty.duration(58 * 60) == "58 min")
        #expect(MeetingProperty.duration(72 * 60) == "1 h 12 min")
        #expect(MeetingProperty.duration(5) == "1 min")
    }
}
