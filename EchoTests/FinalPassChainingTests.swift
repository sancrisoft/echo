//
//  FinalPassChainingTests.swift
//  EchoTests
//
//  SP-005 S3: prior-text chaining across final-pass windows, asserted as pure
//  tables. The chain feeds `DecodingOptions.promptTokens`; the pinned
//  WhisperKit prepends those tokens behind startOfPreviousToken in its prefill
//  path (and re-uses them across temperature-fallback retries), so what this
//  value carries is exactly what conditions the next window's decode.
//

import Testing
import WhisperKit
@testable import Echo

@Suite("FinalPassPromptChain")
struct FinalPassChainingTests {

    @Test("a fresh chain carries no prompt (nil, not empty)")
    func freshChainCarriesNothing() {
        let chain = FinalPassPromptChain()
        #expect(chain.promptTokens == nil)
    }

    @Test("a decoded window's tokens carry into the next window's prompt")
    func normalCarry() {
        var chain = FinalPassPromptChain()
        chain.advance(windowTokens: [5, 6, 7])
        #expect(chain.promptTokens == [5, 6, 7])
    }

    @Test("tokens accumulate across consecutive windows")
    func accumulatesAcrossWindows() {
        var chain = FinalPassPromptChain()
        chain.advance(windowTokens: [1, 2])
        chain.advance(windowTokens: [3, 4])
        #expect(chain.promptTokens == [1, 2, 3, 4])
    }

    @Test("the cap keeps the most recent tokens (the tail)")
    func capKeepsTheTail() {
        var chain = FinalPassPromptChain()
        chain.advance(windowTokens: Array(0..<200))
        #expect(chain.promptTokens == Array(88..<200))
        #expect(chain.promptTokens?.count == FinalPassPromptChain.maxTokens)
    }

    @Test("accumulation past the cap drops the oldest context first")
    func accumulationPastCapDropsOldest() {
        var chain = FinalPassPromptChain()
        chain.advance(windowTokens: Array(0..<100))
        chain.advance(windowTokens: Array(100..<160))
        #expect(chain.promptTokens == Array(48..<160))
    }

    @Test("an empty window resets the chain")
    func emptyWindowResets() {
        var chain = FinalPassPromptChain()
        chain.advance(windowTokens: [1, 2, 3])
        chain.advance(windowTokens: [])
        #expect(chain.promptTokens == nil)
    }

    @Test("chaining restarts cleanly after a reset")
    func restartsAfterReset() {
        var chain = FinalPassPromptChain()
        chain.advance(windowTokens: [1, 2, 3])
        chain.advance(windowTokens: [])
        chain.advance(windowTokens: [9])
        #expect(chain.promptTokens == [9])
    }

    /// Channel boundaries never share context: the pass builds one chain per
    /// channel, and value semantics guarantee they can't alias.
    @Test("per-channel chains are independent values")
    func perChannelIndependence() {
        var micChain = FinalPassPromptChain()
        micChain.advance(windowTokens: [1, 2, 3])
        var systemChain = FinalPassPromptChain()
        let systemBefore = systemChain.promptTokens
        micChain.advance(windowTokens: [4])

        #expect(systemBefore == nil)
        #expect(systemChain.promptTokens == nil)
        systemChain.advance(windowTokens: [7])
        #expect(micChain.promptTokens == [1, 2, 3, 4])
        #expect(systemChain.promptTokens == [7])
    }

    @Test("the cap is half of Whisper's 224-token sample length")
    func capMatchesWhisperBudget() {
        // 224 is the pinned WhisperKit's Constants.maxTokenContext; its own
        // prefill trims prompts to (224/2)−1, so 112 here never over-feeds it.
        #expect(FinalPassPromptChain.maxTokens == 112)
    }
}

/// SP-005 S3: the final pass's decode options — the live thresholds plus the
/// retries live latency forbids.
@Suite("FinalPassDecodeOptions")
struct FinalPassDecodeOptionsTests {

    @Test("flagged windows are re-decoded at increasing temperature (3 retries)")
    func temperatureFallbackIsOn() {
        #expect(FinalizationPass.finalDecodeOptions.temperatureFallbackCount == 3)
        // Contrast: the live path can't afford retries — flagged decodes are
        // used anyway (SP-005 Further Notes reality 3).
        #expect(TranscriptionPipeline.liveDecodeOptions.temperatureFallbackCount == 0)
    }

    @Test("the tightened live thresholds are otherwise unchanged")
    func liveThresholdsCarryOver() {
        let final = FinalizationPass.finalDecodeOptions
        let live = TranscriptionPipeline.liveDecodeOptions

        #expect(final.task == .transcribe)
        #expect(final.compressionRatioThreshold == live.compressionRatioThreshold)
        #expect(final.logProbThreshold == live.logProbThreshold)
        #expect(final.firstTokenLogProbThreshold == live.firstTokenLogProbThreshold)
        #expect(final.noSpeechThreshold == live.noSpeechThreshold)
        #expect(final.wordTimestamps == live.wordTimestamps)
        #expect(final.skipSpecialTokens == live.skipSpecialTokens)
        #expect(final.detectLanguage == false)
    }

    @Test("prefill stays on — it is what routes promptTokens into the decoder")
    func prefillPromptStaysOn() {
        // The pinned WhisperKit only consults promptTokens inside
        // prefillDecoderInputs, which only runs when usePrefillPrompt is true.
        // Turning this off would silently disable the whole chaining slice.
        #expect(FinalizationPass.finalDecodeOptions.usePrefillPrompt)
    }
}
