import Foundation
import Meetings
import Testing

@testable import Workspace

@Suite("When a meeting has nothing to read")
struct MeetingConditionTests {

    private func meta(_ source: TranscriptProvenance.Source?, seconds: TimeInterval = 42) -> MeetingMeta {
        let start = Date(timeIntervalSince1970: 1_787_824_000)
        return MeetingMeta(
            id: UUID(), title: "Meeting", startedAt: start, endedAt: start.addingTimeInterval(seconds),
            segmentCount: 0, hasSummary: false,
            transcriptProvenance: source.map { TranscriptProvenance(source: $0, modelName: "parakeet-tdt-0.6b-v3") })
    }

    private func resolve(
        _ meta: MeetingMeta, loadFailed: Bool = false, segments: Int? = 0, keeps: Bool = false, retry: Bool = false
    ) -> MeetingCondition {
        MeetingCondition.resolve(
            meta, loadFailed: loadFailed, segmentCount: segments, keepsRecording: keeps, canRetry: retry)
    }

    @Test("a finished pass with no words is silent, and can run again only from a kept recording")
    func silent() {
        #expect(resolve(meta(.finalPass), keeps: true) == .silent(duration: 42, canRetranscribe: true))
        #expect(resolve(meta(.finalPass), keeps: false) == .silent(duration: 42, canRetranscribe: false))
    }

    @Test("no words and no outcome yet is a pass still owed, not silence")
    func owed() {
        #expect(resolve(meta(nil)) == .readable)
    }

    @Test("words not read yet decide nothing")
    func loading() {
        #expect(resolve(meta(.finalPass), segments: nil) == .readable)
    }

    @Test("a pass that gave up is a failure, with a Retry while its audio is kept")
    func failed() {
        #expect(resolve(meta(.terminalFailure), retry: true) == .failed(canRetry: true))
        #expect(resolve(meta(.terminalFailure), retry: false) == .failed(canRetry: false))
    }

    @Test("files that cannot be read win over everything else")
    func unreadable() {
        #expect(resolve(meta(.terminalFailure), loadFailed: true, segments: nil) == .unreadable)
    }

    @Test("a meeting with words is a document")
    func readable() {
        #expect(resolve(meta(.finalPass), segments: 12) == .readable)
    }

    @Test("the faces say only what is true of the meeting")
    func copy() {
        #expect(
            MeetingCondition.silentMessage(duration: 42, canRetranscribe: true)
                == "The recording ran for 42 seconds and came back silent. If the wrong input was selected, the audio is still here."
        )
        #expect(
            MeetingCondition.silentMessage(duration: 42, canRetranscribe: false)
                == "The recording ran for 42 seconds and came back silent. Its audio was not kept, so it cannot be transcribed again."
        )
        #expect(!MeetingCondition.failedMessage(canRetry: true).contains("quit"))
        #expect(!MeetingCondition.failedMessage(canRetry: false).contains("survived"))
    }

    @Test("how long it ran: seconds under a minute, the document's minutes after")
    func ranFor() {
        #expect(MeetingCondition.ranFor(1) == "1 second")
        #expect(MeetingCondition.ranFor(42) == "42 seconds")
        #expect(MeetingCondition.ranFor(58 * 60) == "58 min")
    }
}
