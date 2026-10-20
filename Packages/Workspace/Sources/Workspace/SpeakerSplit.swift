//
//  SpeakerSplit.swift
//  Workspace
//
//  How much of a meeting was You and how much Others, by speaking time: the
//  summed length of each channel's segments, over both sums (product owner,
//  2026-10-20). By the channel, because that is what the speaker is — the
//  microphone is You and the Mac's audio is Others — and never a guess at a
//  voice. Two channels that talk over each other both count for the time
//  they spoke.
//

import EchoCore
import Foundation

struct SpeakerSplit: Equatable, Sendable {
    /// You's share of the speaking time, 0 to 1.
    let youShare: Double

    /// You's share as the document writes it: a whole percentage.
    var youPercent: Int { Int((youShare * 100).rounded()) }

    /// Others' share, written so the two always add up to 100: rounded on
    /// their own, 50.5 and 49.5 would read "51% · 50%".
    var othersPercent: Int { 100 - youPercent }

    /// The split of `segments`, or `nil` when none of them lasted any time —
    /// a split of nothing is not 0% each.
    static func measure(_ segments: [TranscriptSegment]) -> SpeakerSplit? {
        var you: TimeInterval = 0
        var others: TimeInterval = 0
        for segment in segments {
            let length = max(0, segment.end - segment.start)
            switch segment.channel {
            case .microphone: you += length
            case .system: others += length
            }
        }
        let total = you + others
        guard total > 0 else { return nil }
        return SpeakerSplit(youShare: you / total)
    }
}
