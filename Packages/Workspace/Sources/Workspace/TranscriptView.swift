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
    let turns: [TranscriptUtterance]
    /// Where the open find's query occurs, in reading order, and which of
    /// those places the user is on.
    var matches: [TranscriptMatch] = []
    var current: Int?

    /// Half the leading a transcript line carries, which a CSS line box puts
    /// above its first line and below its last and a `Text` does not: the
    /// artboard's gaps are measured from line boxes.
    static let halfLeading = EchoFont.transcriptLineSpacing / 2

    /// From the foot of one turn's words to the next turn's speaker.
    static let turnSpacing = EchoLayout.turnGap + halfLeading

    /// From a turn's speaker line to its words.
    static let textSpacing = EchoLayout.turnTextGap + halfLeading

    var body: some View {
        let highlights = Self.highlights(matches, current: current)
        LazyVStack(alignment: .leading, spacing: Self.turnSpacing) {
            ForEach(turns) { turn in
                TranscriptTurn(turn: turn, highlights: highlights[turn.id] ?? [])
                    .id(turn.id)
            }
        }
    }

    /// The matches grouped by turn, each marked current or not.
    static func highlights(_ matches: [TranscriptMatch], current: Int?) -> [UUID: [TurnHighlight]] {
        var byTurn: [UUID: [TurnHighlight]] = [:]
        for (index, match) in matches.enumerated() {
            byTurn[match.turn, default: []].append(TurnHighlight(range: match.range, isCurrent: index == current))
        }
        return byTurn
    }
}

/// A find match inside one turn's words.
struct TurnHighlight: Equatable {
    let range: Range<String.Index>
    let isCurrent: Bool
}

/// One turn: the speaker and the time on one line, sharing a baseline, and the
/// paragraph under them.
private struct TranscriptTurn: View {
    let turn: TranscriptUtterance
    let highlights: [TurnHighlight]

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
            words
                .font(EchoFont.body)
                .lineSpacing(EchoFont.transcriptLineSpacing)
                .foregroundStyle(EchoColor.textProse)
                .textRenderer(InlineHighlightRenderer())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The paragraph, with each match on its fill in the primary ink. The
    /// fill reaches past the letters without moving them, so the words do
    /// not reflow as the query changes.
    private var words: Text {
        guard !highlights.isEmpty else { return Text(turn.text) }
        var text = Text(verbatim: "")
        var cursor = turn.text.startIndex
        for highlight in highlights {
            if cursor < highlight.range.lowerBound {
                text = Text("\(text)\(Text(turn.text[cursor..<highlight.range.lowerBound]))")
            }
            let match = Text(turn.text[highlight.range])
                .foregroundStyle(EchoColor.textPrimary)
                .customAttribute(
                    InlineHighlight(
                        fill: highlight.isCurrent ? EchoColor.findCurrentMatch : EchoColor.accentWash,
                        radius: EchoRadius.findMatch,
                        leading: EchoControl.findMatchInset.width,
                        trailing: EchoControl.findMatchInset.width,
                        vertical: EchoControl.findMatchInset.height))
            text = Text("\(text)\(match)")
            cursor = highlight.range.upperBound
        }
        if cursor < turn.text.endIndex {
            text = Text("\(text)\(Text(turn.text[cursor...]))")
        }
        return text
    }
}
