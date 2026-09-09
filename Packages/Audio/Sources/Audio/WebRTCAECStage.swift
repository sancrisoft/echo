//
//  WebRTCAECStage.swift
//  Audio
//
//  `AECStage` backed by the vendored WebRTC audio-processing module (AEC3)
//  through the `APMEchoCanceller` bridge.
//

import Foundation
import Synchronization
import WebRTCAECBridge

/// The seam contract delivers arbitrary-length 16 kHz mono buffers from two
/// different real-time threads; this stage owns both the 160-sample (10 ms)
/// framing and the locking. Per-call output length may differ from input
/// length because sub-frame remainders carry to the next call, but cumulative
/// samples out equal cumulative samples in, in order — the last sub-frame
/// remainder stays buffered until completed.
public final class WebRTCAECStage: AECStage {

    private static let frameSize = Int(APMEchoCancellerFrameSize)

    /// One lock serializes both paths: the bridge is not thread-safe, and mic
    /// and far-end buffers arrive on different capture threads — the mic on
    /// the AVAudioEngine render thread, the far end on the system tap's IO
    /// queue. Frames are 10 ms and processed far faster than real time, so
    /// contention is negligible. A lock rather than an actor because both
    /// callers are real-time paths that cannot take a suspension point, and
    /// because the mic path must return its processed samples to the same
    /// callback that handed them over.
    ///
    /// `@unchecked Sendable` because it holds the `APMEchoCanceller` bridge
    /// object, which is not `Sendable` and is explicitly documented as not
    /// thread-safe. This lock is the only thing that ever touches it.
    private struct State: @unchecked Sendable {
        var engine: APMEchoCanceller?
        var micCarry: [Float] = []
        var farCarry: [Float] = []
        var healthy: Bool
        /// Baseline is healthy so the hook fires only on an actual failure
        /// and again on recovery — once per episode, never per frame, so a
        /// flapping engine cannot spam notices.
        var lastReportedHealth = true
        var eventHandler: (@Sendable (_ healthy: Bool) -> Void)?
    }

    private let state: Mutex<State>

    public init() {
        let engine = APMEchoCanceller()
        state = Mutex(State(engine: engine, healthy: engine != nil))
    }

    /// Test seam: constructs the stage in the state a failed engine init
    /// leaves it in (the pass-through degradation path). Init failure is not
    /// inducible through the real bridge.
    public init(failedEngine: ()) {
        state = Mutex(State(engine: nil, healthy: false))
    }

    /// Engine-health hook for the echo-handling mode machine: Cancelling →
    /// Degraded on engine failure, back on recovery. Called with `false` when
    /// the engine fails at init or during processing and `true` when
    /// processing succeeds again — once per transition. May be invoked on
    /// either capture thread, and always outside the stage's lock.
    public var onEngineEvent: (@Sendable (_ healthy: Bool) -> Void)? {
        get { state.withLock { $0.eventHandler } }
        set { state.withLock { $0.eventHandler = newValue } }
    }

    /// `true` while the engine exists and its last processing call succeeded.
    /// A stage without a working engine passes mic audio through untouched:
    /// degrade, never lose audio.
    public var isHealthy: Bool {
        state.withLock { $0.healthy }
    }

    public func processMicSamples(_ samples: [Float]) -> [Float] {
        let outcome = state.withLock { state -> (output: [Float], report: ((Bool) -> Void)?, ok: Bool) in
            guard let engine = state.engine else {
                // Engine never came up: pass mic audio through untouched.
                return (samples, Self.noteHealth(&state, false), false)
            }

            state.micCarry.append(contentsOf: samples)
            var output: [Float] = []
            output.reserveCapacity((state.micCarry.count / Self.frameSize) * Self.frameSize)

            var allOk = true
            var start = 0
            while state.micCarry.count - start >= Self.frameSize {
                var frame = Array(state.micCarry[start..<start + Self.frameSize])
                let ok = frame.withUnsafeMutableBufferPointer { buffer -> Bool in
                    guard let base = buffer.baseAddress else { return false }
                    return engine.processCaptureFrame(base)
                }
                if ok {
                    output.append(contentsOf: frame)
                } else {
                    // Failed frame: emit the raw input instead of possibly
                    // half-processed samples — never lose mic audio.
                    output.append(contentsOf: state.micCarry[start..<start + Self.frameSize])
                    allOk = false
                }
                start += Self.frameSize
            }
            state.micCarry.removeFirst(start)

            // Only whole processed frames are evidence of engine health.
            let report = start > 0 ? Self.noteHealth(&state, allOk) : nil
            return (output, report, allOk)
        }
        outcome.report?(outcome.ok)
        return outcome.output
    }

    public func feedFarEnd(_ samples: [Float]) {
        let outcome = state.withLock { state -> (report: ((Bool) -> Void)?, ok: Bool) in
            guard let engine = state.engine else {
                return (Self.noteHealth(&state, false), false)
            }

            state.farCarry.append(contentsOf: samples)
            var allOk = true
            var start = 0
            while state.farCarry.count - start >= Self.frameSize {
                let ok = state.farCarry[start..<start + Self.frameSize].withUnsafeBufferPointer {
                    buffer -> Bool in
                    guard let base = buffer.baseAddress else { return false }
                    return engine.feedRenderFrame(base)
                }
                allOk = allOk && ok
                start += Self.frameSize
            }
            state.farCarry.removeFirst(start)

            let report = start > 0 ? Self.noteHealth(&state, allOk) : nil
            return (report, allOk)
        }
        outcome.report?(outcome.ok)
    }

    public func reset() {
        let outcome = state.withLock { state -> (report: ((Bool) -> Void)?, ok: Bool) in
            // Sub-frame carries belong to the pre-reset stream: reset and
            // re-converge on route change, and dropping <10 ms is inaudible.
            state.micCarry.removeAll(keepingCapacity: true)
            state.farCarry.removeAll(keepingCapacity: true)

            guard let engine = state.engine else { return (nil, false) }
            let ok = engine.reset()
            return (Self.noteHealth(&state, ok), ok)
        }
        outcome.report?(outcome.ok)
    }

    /// Updates health state under the held lock and returns the handler to
    /// invoke (after unlocking — the hook must never run inside the lock)
    /// when this is a transition, `nil` otherwise.
    private static func noteHealth(_ state: inout State, _ ok: Bool) -> (@Sendable (Bool) -> Void)? {
        state.healthy = ok
        guard ok != state.lastReportedHealth else { return nil }
        state.lastReportedHealth = ok
        return state.eventHandler
    }
}
