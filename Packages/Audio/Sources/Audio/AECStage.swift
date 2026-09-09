//
//  AECStage.swift
//  Audio
//
//  The echo-cancellation seam: a stage that sits between the capture
//  callbacks and the pipeline. The mic (near-end) stream is REPLACED by the
//  stage's output; the far-end reference is a read-only copy of the system
//  stream, and nothing here ever writes back into it.
//

/// Consumes 16 kHz mono Float samples of arbitrary length — 10 ms framing is
/// the engine's internal concern. Implementations must be safe to call from
/// the real-time capture callbacks (mic and system audio arrive on different
/// threads), hence `Sendable`.
public protocol AECStage: AnyObject, Sendable {
    /// Returns the near-end samples with any speaker bleed removed.
    func processMicSamples(_ samples: [Float]) -> [Float]
    /// Feeds far-end reference samples (what the loudspeakers are playing).
    func feedFarEnd(_ samples: [Float])
    /// Drops all adaptation state, e.g. on an output-route change: reset and
    /// re-converge.
    func reset()
}

/// No-op stage: mic samples pass through untouched, the far end is ignored.
/// Used on routes with no cancellation, and it is what makes the pass-through
/// modes bit-identical rather than merely similar.
public final class PassthroughAECStage: AECStage {
    public init() {}
    public func processMicSamples(_ samples: [Float]) -> [Float] { samples }
    public func feedFarEnd(_ samples: [Float]) {}
    public func reset() {}
}
