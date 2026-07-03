//
//  SwitchingAECStage.swift
//  Echo
//
//  Routes the mic/far-end streams to the AEC engine or to pass-through
//  according to the current `EchoHandlingMode` (SP-001 state diagram).
//  Deliberately dumb: mode decisions live in `EchoModeMachine`; this stage
//  only applies the current mode to the audio path.
//

import Foundation

/// Thread-safe mode-driven delegate: `setMode` is called from the main actor
/// on mode-machine transitions while `processMicSamples`/`feedFarEnd` arrive
/// on the two real-time capture threads.
nonisolated final class SwitchingAECStage: AECStage, @unchecked Sendable {

    private let lock = NSLock()
    private let engineStage: any AECStage
    private let passthroughStage = PassthroughAECStage()
    private var mode: EchoHandlingMode

    init(engineStage: any AECStage, mode: EchoHandlingMode) {
        self.engineStage = engineStage
        self.mode = mode
    }

    var currentMode: EchoHandlingMode {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    /// Applies a mode-machine transition. Re-engaging the engine after a
    /// stretch without far-end feed resets it first: the engine's buffered
    /// reference no longer lines up with the live mic, and adapting against
    /// it would corrupt convergence (SP-001: reset and re-converge).
    func setMode(_ newMode: EchoHandlingMode) {
        lock.lock()
        let wasEngineFed = Self.feedsEngine(mode)
        mode = newMode
        let reEngaged = Self.feedsEngine(newMode) && !wasEngineFed
        lock.unlock()
        // Outside the lock: the engine stage has its own lock and its health
        // hook must never fire under ours.
        if reEngaged { engineStage.reset() }
    }

    func processMicSamples(_ samples: [Float]) -> [Float] {
        activeStage().processMicSamples(samples)
    }

    func feedFarEnd(_ samples: [Float]) {
        activeStage().feedFarEnd(samples)
    }

    func reset() {
        engineStage.reset()
    }

    private func activeStage() -> any AECStage {
        lock.lock()
        defer { lock.unlock() }
        return Self.feedsEngine(mode) ? engineStage : passthroughStage
    }

    /// Cancelling feeds the engine, and Degraded does too: while unhealthy
    /// the engine already passes raw mic through internally, and it only
    /// detects recovery on continued frame processing — starving it would
    /// make Degraded → Cancelling unreachable. Mic and far end keep flowing
    /// in lockstep there, so no stale-reference problem arises. Bypassed and
    /// DedupOnly are pure pass-through: the mic path must be bit-identical
    /// (SP-001 NFR) and an idle engine must not accumulate a far-end buffer.
    private static func feedsEngine(_ mode: EchoHandlingMode) -> Bool {
        mode == .cancelling || mode == .degraded
    }
}
