import EchoCore
import Foundation
import Meetings
import Testing

@testable import Workspace

@Suite("The facts under a meeting's title")
struct MeetingPropertiesTests {

    private let start = Date(timeIntervalSince1970: 1_787_824_000)

    private func meta(
        minutes: Double = 58, words: Int? = 5512, capture: CaptureScopeRecord? = .app(named: "Zoom"),
        hasSummary: Bool = true, provenance: TranscriptProvenance? = nil
    ) -> MeetingMeta {
        MeetingMeta(
            id: UUID(), title: "GoCoInvest onboarding", startedAt: start,
            endedAt: start.addingTimeInterval(minutes * 60), segmentCount: 3, hasSummary: hasSummary,
            wordCount: words, transcriptProvenance: provenance, captureScope: capture)
    }

    @Test("a complete meeting has every row, in the artboard's order")
    func everyRow() {
        let meeting = meta()
        #expect(
            MeetingProperty.summaryRows(for: meeting) == [
                .date(start: meeting.startedAt, end: meeting.endedAt),
                .duration(58 * 60),
                .words(5512),
                .capture("Zoom only"),
                .status(.summarized),
            ])
    }

    @Test("a meeting that captured everything says so")
    func everything() {
        #expect(MeetingProperty.summaryRows(for: meta(capture: .everything)).contains(.capture("Everything")))
    }

    @Test("a fact the meeting never kept has no row, rather than an empty one")
    func missingFacts() {
        let rows = MeetingProperty.summaryRows(for: meta(words: nil, capture: nil))
        #expect(!rows.contains { if case .words = $0 { true } else { false } })
        #expect(!rows.contains { if case .capture = $0 { true } else { false } })
        #expect(rows.count == 3)
    }

    @Test("the status row is the meeting's status")
    func status() {
        #expect(MeetingProperty.summaryRows(for: meta(hasSummary: false)).last == .status(.transcribed))
    }

    // MARK: The Transcript tab

    private let segments = [
        TranscriptSegment(channel: .microphone, text: "Sounds good.", start: 0, end: 18),
        TranscriptSegment(channel: .system, text: "Let me show you.", start: 20, end: 102),
    ]

    @Test("the Transcript tab trades the duration and the summary's status for the speakers and its own")
    func transcriptRows() {
        let meeting = meta(provenance: TranscriptProvenance(source: .finalPass, modelName: "parakeet-tdt-0.6b-v3"))
        #expect(
            MeetingProperty.transcriptRows(for: meeting, segments: segments) == [
                .date(start: meeting.startedAt, end: meeting.endedAt),
                .speakers(SpeakerSplit(youShare: 0.18)),
                .words(5512),
                .transcript(TranscriptStatus(label: "Final", tone: .accent, model: "parakeet-tdt-0.6b-v3")),
            ])
    }

    @Test("a transcript with no speaking time has no split, rather than 0% each")
    func noSplit() {
        let rows = MeetingProperty.transcriptRows(for: meta(), segments: [])
        #expect(!rows.contains { if case .speakers = $0 { true } else { false } })
    }

    @Test("a transcript names the model that wrote it only when there are words it wrote")
    func provenance() {
        #expect(TranscriptStatus.resolve(meta()).model == nil)
        let failed = meta(provenance: TranscriptProvenance(source: .terminalFailure, modelName: "parakeet-tdt-0.6b-v3"))
        #expect(
            TranscriptStatus.resolve(failed)
                == TranscriptStatus(label: "Transcription failed", tone: .danger, model: nil))
        let draft = meta(provenance: TranscriptProvenance(source: .liveFloor, modelName: "live"))
        #expect(TranscriptStatus.resolve(draft) == TranscriptStatus(label: "Draft", tone: .warning, model: "live"))
    }

    @Test("a duration is written to the minute, and never as nothing")
    func duration() {
        #expect(MeetingProperty.duration(58 * 60) == "58 min")
        #expect(MeetingProperty.duration(72 * 60) == "1 h 12 min")
        #expect(MeetingProperty.duration(5) == "1 min")
    }
}
