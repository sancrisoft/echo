//
//  PassProgress.swift
//  Transcription
//
//  The finalizing UI's single progress source: decoded audio time over the
//  total retained duration across both channels — never a second
//  independently-maintained number. The fraction is monotonic, in [0, 1], and
//  reaches exactly 1.0 when every channel is accounted for. A pure value,
//  table-tested without audio.
//

import Foundation
import Synchronization

public struct PassProgress: Sendable {

    private let totals: [Double]
    private var positions: [Double]
    private var reported: Double

    /// One entry per channel: that channel's total retained samples. No
    /// retained audio at all means nothing to decode — complete immediately,
    /// so the fraction still ends at 1.0.
    public init(channelTotalSamples: [Int]) {
        totals = channelTotalSamples.map { Double(max(0, $0)) }
        positions = Array(repeating: 0, count: totals.count)
        reported = totals.reduce(0, +) > 0 ? 0 : 1
    }

    /// The fraction the UI shows — monotonic, never past 1.
    public var fraction: Double { reported }

    /// `channel` is decoded through `samplePosition` on its own timeline.
    /// Backward positions and out-of-range channels are ignored, so the
    /// fraction can never regress.
    @discardableResult
    public mutating func advance(channel: Int, decodedThrough samplePosition: Int) -> Double {
        guard positions.indices.contains(channel) else { return reported }
        positions[channel] = min(max(positions[channel], Double(samplePosition)), totals[channel])
        return recompute()
    }

    /// `channel` finished: it contributes its full share, so the overall
    /// fraction ends at exactly 1.0 once every channel has finished.
    @discardableResult
    public mutating func finishChannel(_ channel: Int) -> Double {
        guard positions.indices.contains(channel) else { return reported }
        positions[channel] = totals[channel]
        return recompute()
    }

    private mutating func recompute() -> Double {
        let total = totals.reduce(0, +)
        guard total > 0 else {
            reported = 1
            return reported
        }
        reported = max(reported, min(1, positions.reduce(0, +) / total))
        return reported
    }
}

/// Shared holder for the pass's progress accumulator, so the value type
/// itself stays pure and table-testable while the sharing is explicit.
///
/// Two writers, neither of them the actor the pass runs on: FluidAudio's
/// progress-stream consumer (its own child task in the decode group) and the
/// channel loop. A `Mutex` rather than an actor because both writers are
/// synchronous callbacks that must not hop to observe a fraction (ADR-002).
final class SharedPassProgress: Sendable {
    private let progress: Mutex<PassProgress>

    init(channelTotalSamples: [Int]) {
        progress = Mutex(PassProgress(channelTotalSamples: channelTotalSamples))
    }

    var fraction: Double {
        progress.withLock { $0.fraction }
    }

    func advance(channel: Int, decodedThrough samplePosition: Int) -> Double {
        progress.withLock { $0.advance(channel: channel, decodedThrough: samplePosition) }
    }

    func finishChannel(_ channel: Int) -> Double {
        progress.withLock { $0.finishChannel(channel) }
    }
}
