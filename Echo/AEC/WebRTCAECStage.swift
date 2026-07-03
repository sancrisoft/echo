//
//  WebRTCAECStage.swift
//  Echo
//
//  `AECStage` backed by the vendored WebRTC audio-processing module (AEC3)
//  through the `APMEchoCanceller` bridge (ADR-001).
//

import Foundation

/// The seam contract delivers arbitrary-length 16 kHz mono buffers from two
/// different real-time threads; this stage owns both the 160-sample (10 ms,
/// ADR-002) framing and the locking. Per-call output length may differ from
/// input length because sub-frame remainders carry to the next call, but
/// cumulative samples out equal cumulative samples in, in order (the last
/// sub-frame remainder stays buffered until completed).
nonisolated final class WebRTCAECStage: AECStage, @unchecked Sendable {

    private static let frameSize = Int(APMEchoCancellerFrameSize)

    // A single lock serializes both paths: the bridge is not thread-safe,
    // and mic and far-end buffers arrive on different capture threads.
    // Frames are 10 ms and processed far faster than real time, so
    // contention is negligible.
    private let lock = NSLock()
    private let engine: APMEchoCanceller?
    private var micCarry: [Float] = []
    private var farCarry: [Float] = []
    private var healthy: Bool
    // Baseline is healthy so the hook fires only on an actual failure and
    // again on recovery — once per episode, never per frame (SP-001: no
    // notice spam on flapping).
    private var lastReportedHealth = true
    private var eventHandler: (@Sendable (_ healthy: Bool) -> Void)?

    /// Engine-health hook for the echo-handling mode machine (SP-001:
    /// Cancelling → Degraded on engine failure, back on recovery). Called
    /// with `false` when the engine fails at init or during processing and
    /// `true` when processing succeeds again — once per transition. May be
    /// invoked on either capture thread, outside the stage's lock.
    var onEngineEvent: (@Sendable (_ healthy: Bool) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return eventHandler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            eventHandler = newValue
        }
    }

    /// `true` while the engine exists and its last processing call
    /// succeeded. A stage without a working engine passes mic audio through
    /// untouched (SP-001: degrade, never lose audio).
    var isHealthy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return healthy
    }

    init() {
        engine = APMEchoCanceller()
        healthy = engine != nil
    }

    /// Test seam: constructs the stage in the state a failed engine init
    /// leaves it in (the passthrough degradation path). Init failure is not
    /// inducible through the real bridge.
    init(failedEngine: ()) {
        engine = nil
        healthy = false
    }

    func processMicSamples(_ samples: [Float]) -> [Float] {
        lock.lock()

        guard let engine else {
            let report = noteHealthLocked(false)
            lock.unlock()
            report?(false)
            // Engine never came up: pass mic audio through untouched.
            return samples
        }

        micCarry.append(contentsOf: samples)
        var output: [Float] = []
        output.reserveCapacity((micCarry.count / Self.frameSize) * Self.frameSize)

        var allOk = true
        var start = 0
        while micCarry.count - start >= Self.frameSize {
            var frame = Array(micCarry[start ..< start + Self.frameSize])
            let ok = frame.withUnsafeMutableBufferPointer {
                engine.processCaptureFrame($0.baseAddress!)
            }
            if ok {
                output.append(contentsOf: frame)
            } else {
                // Failed frame: emit the raw input instead of possibly
                // half-processed samples — never lose mic audio.
                output.append(contentsOf: micCarry[start ..< start + Self.frameSize])
                allOk = false
            }
            start += Self.frameSize
        }
        micCarry.removeFirst(start)

        // Only whole processed frames are evidence of engine health.
        let report = start > 0 ? noteHealthLocked(allOk) : nil
        lock.unlock()
        report?(allOk)
        return output
    }

    func feedFarEnd(_ samples: [Float]) {
        lock.lock()

        guard let engine else {
            let report = noteHealthLocked(false)
            lock.unlock()
            report?(false)
            return
        }

        farCarry.append(contentsOf: samples)
        var allOk = true
        var start = 0
        while farCarry.count - start >= Self.frameSize {
            let ok = farCarry[start ..< start + Self.frameSize].withUnsafeBufferPointer {
                engine.feedRenderFrame($0.baseAddress!)
            }
            allOk = allOk && ok
            start += Self.frameSize
        }
        farCarry.removeFirst(start)

        let report = start > 0 ? noteHealthLocked(allOk) : nil
        lock.unlock()
        report?(allOk)
    }

    func reset() {
        lock.lock()

        // Sub-frame carries belong to the pre-reset stream (SP-001: reset
        // and re-converge on route change); dropping <10 ms is inaudible.
        micCarry.removeAll(keepingCapacity: true)
        farCarry.removeAll(keepingCapacity: true)

        guard let engine else {
            lock.unlock()
            return
        }
        let ok = engine.reset()
        let report = noteHealthLocked(ok)
        lock.unlock()
        report?(ok)
    }

    /// Updates health state under the caller-held lock and returns the
    /// handler to invoke (after unlocking — the hook must never run inside
    /// the lock) when this is a transition, `nil` otherwise.
    private func noteHealthLocked(_ ok: Bool) -> (@Sendable (Bool) -> Void)? {
        healthy = ok
        guard ok != lastReportedHealth else { return nil }
        lastReportedHealth = ok
        return eventHandler
    }
}
