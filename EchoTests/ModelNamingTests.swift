//
//  ModelNamingTests.swift
//  EchoTests
//
//  Naming-honesty tripwire: every user-visible model name must name the
//  checkpoint actually running, and the on-disk contract strings must never
//  drift from it. `modelID` is the harder half — it lands in
//  `TranscriptProvenance.modelName` inside meta.json, so a rename silently
//  rewrites the meaning of every meeting recorded after it. Cheap by design:
//  if a future edit changes either constant, this fails before any eyeball
//  pass.
//

import Testing
@testable import Echo

@Suite("Model display naming")
struct ModelNamingTests {

    @Test("the transcription model is named as the checkpoint that runs")
    func transcriptionModelNamesParakeet() {
        #expect(ParakeetModelManager.modelDisplayName.localizedCaseInsensitiveContains("Parakeet"))
        #expect(ParakeetModelManager.modelDisplaySize == "~480 MB")
        // No leftover Whisper claim anywhere in the surface strings.
        #expect(!ParakeetModelManager.modelDisplayName.localizedCaseInsensitiveContains("whisper"))
    }

    @Test("the persisted checkpoint id is the on-disk contract")
    func provenanceModelIDIsStable() {
        #expect(ParakeetModelManager.modelID == "parakeet-tdt-0.6b-v3")
    }

    @Test("CC-BY-4.0 attribution names NVIDIA and the licence")
    func attributionIsPresent() {
        #expect(ParakeetModelManager.attribution.contains("NVIDIA"))
        #expect(ParakeetModelManager.attribution.contains("CC-BY-4.0"))
    }

    @Test("the summary model names the checkpoint that runs")
    func summaryModelNamesQwen() {
        #expect(SummaryModelManager.modelDisplayName.localizedCaseInsensitiveContains("qwen"))
    }
}
