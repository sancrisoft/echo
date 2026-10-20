import EchoCore
import Testing

@testable import Workspace

@Suite("The speaker split")
struct SpeakerSplitTests {

    @Test("You and Others by speaking time, each channel's segments summed")
    func bySpeakingTime() throws {
        let split = try #require(
            SpeakerSplit.measure([
                TranscriptSegment(channel: .microphone, text: "One.", start: 0, end: 10),
                TranscriptSegment(channel: .system, text: "Two.", start: 10, end: 40),
                TranscriptSegment(channel: .microphone, text: "Three.", start: 40, end: 50),
                TranscriptSegment(channel: .system, text: "Four.", start: 50, end: 70),
            ]))
        #expect(split.youPercent == 29)
        #expect(split.othersPercent == 71)
    }

    @Test("the two shares always add up to a hundred")
    func addsUp() {
        for you in [0.0, 0.005, 0.125, 0.335, 0.5, 0.505, 0.995, 1] {
            let split = SpeakerSplit(youShare: you)
            #expect(split.youPercent + split.othersPercent == 100)
        }
    }

    @Test("talking over each other counts for both")
    func overlap() {
        let split = SpeakerSplit.measure([
            TranscriptSegment(channel: .microphone, text: "Wait—", start: 0, end: 10),
            TranscriptSegment(channel: .system, text: "So—", start: 0, end: 10),
        ])
        #expect(split == SpeakerSplit(youShare: 0.5))
    }

    @Test("a speaker who never spoke is 0%, and no speaking time at all is no split")
    func edges() {
        #expect(
            SpeakerSplit.measure([TranscriptSegment(channel: .system, text: "Hello?", start: 0, end: 4)])?.youPercent
                == 0)
        #expect(SpeakerSplit.measure([]) == nil)
        #expect(SpeakerSplit.measure([TranscriptSegment(channel: .microphone, text: "", start: 3, end: 3)]) == nil)
    }
}
