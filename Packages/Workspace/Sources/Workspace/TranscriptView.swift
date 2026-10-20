//
//  TranscriptView.swift
//  Workspace
//
//  The transcript as a document rather than a log, as the transcript artboard
//  draws it: each turn is who spoke and when on one line, then what was said
//  as a paragraph. You in the accent, Others in grey. Those are the only two
//  labels there are, because the speaker is the channel the audio came in on —
//  the microphone or the Mac's own audio — and never a guess at a voice.
//
//  Turns, not segments: `TranscriptUtterance` merges a speaker's run of
//  segments and drops a lone "yeah" that would break the other speaker's run,
//  so the page reads the way the conversation went.
//

import DesignSystem
import EchoCore
import Meetings
import SwiftUI

struct TranscriptView: View {
    let segments: [TranscriptSegment]

    /// Half the leading a transcript line carries, which a CSS line box puts
    /// above its first line and below its last and a `Text` does not: the
    /// artboard's gaps are measured from line boxes.
    static let halfLeading = EchoFont.transcriptLineSpacing / 2

    /// From the foot of one turn's words to the next turn's speaker.
    static let turnSpacing = EchoLayout.turnGap + halfLeading

    /// From a turn's speaker line to its words.
    static let textSpacing = EchoLayout.turnTextGap + halfLeading

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Self.turnSpacing) {
            ForEach(TranscriptUtterance.derive(from: segments)) { turn in
                TranscriptTurn(turn: turn)
                    .id(turn.id)
            }
        }
    }
}

/// One turn: the speaker and the time on one line, sharing a baseline, and the
/// paragraph under them.
private struct TranscriptTurn: View {
    let turn: TranscriptUtterance

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptView.textSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: EchoLayout.turnLabelGap) {
                Text(turn.speaker.displayName)
                    .font(EchoFont.speaker)
                    .tracking(EchoFont.speakerTracking)
                    .foregroundStyle(turn.speaker == .me ? EchoColor.accent : EchoColor.textSecondary)
                Text(MeetingExport.timestamp(turn.start))
                    .font(EchoFont.timestamp)
                    .foregroundStyle(EchoColor.textQuaternary)
            }
            Text(turn.text)
                .font(EchoFont.body)
                .lineSpacing(EchoFont.transcriptLineSpacing)
                .foregroundStyle(EchoColor.textProse)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
