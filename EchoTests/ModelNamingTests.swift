//
//  ModelNamingTests.swift
//  EchoTests
//
//  SP-005 user story 17 tripwire: every user-visible model name must name
//  the checkpoint actually running. The live checkpoint
//  (`large-v3-v20240930_626MB`) is large-v3-TURBO — a 4-layer decoder,
//  mixed-bit quantized — so a display name claiming plain "large-v3" would
//  claim an accuracy class the app isn't running. The final-pass model is
//  the one that really is the full large-v3 decoder. Cheap by design: if a
//  future edit reverts either constant, this fails before any eyeball pass.
//

import Testing
@testable import Echo

@Suite("Model display naming")
struct ModelNamingTests {

    @Test("the live speech model is named as the turbo checkpoint")
    func liveModelNamesTurbo() {
        #expect(TranscriptionPipeline.modelDisplayName.localizedCaseInsensitiveContains("turbo"))
        #expect(TranscriptionPipeline.modelDisplaySize == "626 MB")
    }

    @Test("the final-pass model is named distinctly as the full large-v3")
    func finalPassModelNamesFull() {
        let name = FinalPassModelManager.modelDisplayName
        #expect(name.localizedCaseInsensitiveContains("large-v3"))
        // The full model must never be confused with (or named as) the turbo.
        #expect(!name.localizedCaseInsensitiveContains("turbo"))
        #expect(name != TranscriptionPipeline.modelDisplayName)
        #expect(FinalPassModelManager.modelDisplaySize == "947 MB")
    }
}
