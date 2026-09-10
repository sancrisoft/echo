//
//  SwitchingAECStage.swift
//  Audio
//
//  Routes the mic and far-end streams to the AEC engine or to pass-through
//  according to the current `EchoHandlingMode`. Deliberately dumb: mode
//  decisions live in `EchoModeMachine`; this stage only applies the current
//  mode to the audio path.
//

import Foundation
import Synchronization

/// Mode-driven delegate: `setMode` is called on a mode-machine transition
/// (from Recording) while `processMicSamples` and `feedFarEnd` arrive on the
/// two real-time capture threads.
public final class SwitchingAECStage: AECStage {

    private let engineStage: any AECStage
    private let passthroughStage = PassthroughAECStage()
    private let mode: Mutex<EchoHandlingMode>

    public init(engineStage: any AECStage, mode: EchoHandlingMode) {
        self.engineStage = engineStage
        self.mode = Mutex(mode)
    }

    public var currentMode: EchoHandlingMode {
        mode.withLock { $0 }
    }

    /// Applies a mode-machine transition. Re-engaging the engine after a
    /// stretch without far-end feed resets it FIRST: the engine's buffered
    /// reference no longer lines up with the live mic, and adapting against
    /// it would corrupt convergence.
    public func setMode(_ newMode: EchoHandlingMode) {
        let reEngaged = mode.withLock { mode -> Bool in
            let wasEngineFed = Self.feedsEngine(mode)
            mode = newMode
            return Self.feedsEngine(newMode) && !wasEngineFed
        }
        // Outside the lock: the engine stage has its own lock and its health
        // hook must never fire under ours.
        if reEngaged { engineStage.reset() }
    }

    public func processMicSamples(_ samples: [Float]) -> [Float] {
        activeStage().processMicSamples(samples)
    }

    public func feedFarEnd(_ samples: [Float]) {
        activeStage().feedFarEnd(samples)
    }

    public func reset() {
        engineStage.reset()
    }

    private func activeStage() -> any AECStage {
        Self.feedsEngine(mode.withLock { $0 }) ? engineStage : passthroughStage
    }

    /// Cancelling feeds the engine, and Degraded does too: while unhealthy
    /// the engine already passes raw mic through internally, and it only
    /// detects recovery on continued frame processing — starving it would
    /// make Degraded → Cancelling unreachable. Mic and far end keep flowing
    /// in lockstep there, so no stale-reference problem arises. Bypassed and
    /// DedupOnly are pure pass-through: the mic path must be bit-identical
    /// and an idle engine must not accumulate a far-end buffer.
    private static func feedsEngine(_ mode: EchoHandlingMode) -> Bool {
        mode == .cancelling || mode == .degraded
    }
}
