import DesignSystem
import EchoCore
import Testing

@testable import Workspace

@Suite("Transcript turns")
struct TranscriptLayoutTests {

    @Test("turns sit the artboard's distance apart, measured from line boxes")
    func spacing() {
        let half = EchoFont.transcriptLineSpacing / 2
        // Within a rounding error: the same sum, folded at compile time on
        // one side and added at run time on the other.
        #expect(abs(TranscriptView.turnSpacing - (EchoLayout.turnGap + half)) < 1e-9)
        #expect(abs(TranscriptView.textSpacing - (EchoLayout.turnTextGap + half)) < 1e-9)
    }

    @Test("the two labels are the two channels, and there is no third")
    func twoLabels() {
        #expect(AudioChannel.allCases.map { Speaker(defaultFor: $0).displayName } == ["You", "Others"])
    }
}
