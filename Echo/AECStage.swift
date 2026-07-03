//
//  AECStage.swift
//  Echo
//
//  The echo-cancellation seam (ADR-002): a stage that sits between the
//  capture callbacks and `TranscriptionPipeline.ingest`. The mic (near-end)
//  stream is replaced by the stage's output; the far-end reference is a
//  read-only copy of the system stream.
//

/// Consumes 16 kHz mono Float samples of arbitrary length — 10 ms framing is
/// the engine's internal concern. Implementations must be safe to call from
/// the real-time capture callbacks (mic and system audio arrive on different
/// threads), hence `Sendable`.
nonisolated protocol AECStage: AnyObject, Sendable {
    /// Returns the near-end samples with any speaker bleed removed.
    func processMicSamples(_ samples: [Float]) -> [Float]
    /// Feeds far-end reference samples (what the loudspeakers are playing).
    func feedFarEnd(_ samples: [Float])
    /// Drops all adaptation state, e.g. on an output-route change (SP-001:
    /// reset and re-converge).
    func reset()
}

/// No-op stage: mic samples pass through untouched, the far end is ignored.
/// Used on routes with no cancellation and until S2 lands the real engine.
nonisolated final class PassthroughAECStage: AECStage {
    func processMicSamples(_ samples: [Float]) -> [Float] { samples }
    func feedFarEnd(_ samples: [Float]) {}
    func reset() {}
}
