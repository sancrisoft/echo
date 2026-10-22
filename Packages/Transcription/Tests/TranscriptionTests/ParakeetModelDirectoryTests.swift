//
//  ParakeetModelDirectoryTests.swift
//  TranscriptionTests
//
//  Pins where the model files actually go.
//
//  FluidAudio does not use the directory it is handed. It discards that
//  directory's LAST component and appends its own `Repo.folderName`, which
//  for v3 is the Hugging Face slug with `-coreml` stripped by a `default`
//  branch. So `Models/parakeet-tdt-0.6b-v3-coreml` resolves to
//  `Models/parakeet-tdt-0.6b-v3`, the `-coreml` directory is never created,
//  and only the PARENT of what we pass is load-bearing.
//
//  Every expectation below is a LITERAL, deliberately. A test that re-derived
//  the answer through `AsrModels` or `Repo.folderName` would follow an
//  upstream rename in silence — and the failure it would be following is not
//  loud: readiness would simply keep reporting false, so the app would
//  re-download 480 MB on every launch while the real snapshot sat untouched
//  in a sibling folder. This is the same technique, and the same reasoning,
//  as the on-disk layout assertions in ModelDeliveryTests.
//

import EchoCore
import EchoCoreTestSupport
import FluidAudio
import Foundation
import Testing
import Transcription

@Suite("Parakeet model directory resolution")
struct ParakeetModelDirectoryTests {

    /// v3 at int8, spelled out rather than asked for.
    private static let requiredFiles = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecisionv3.mlmodelc",
        "parakeet_vocab.json",
    ]

    @Test func theDirectoryHandedToTheLibraryKeepsTheRepoSlug() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url

        #expect(
            ParakeetModel.modelDirectory(in: root).lastPathComponent
                == "parakeet-tdt-0.6b-v3-coreml"
        )
    }

    @Test func theResolvedDirectoryDropsTheCoremlSuffix() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url

        #expect(ParakeetModel.resolvedModelDirectory(in: root).lastPathComponent == "parakeet-tdt-0.6b-v3")
        #expect(
            ParakeetModel.resolvedModelDirectory(in: root).path
                == root.appending(path: "parakeet-tdt-0.6b-v3").path
        )
    }

    /// The invariant that is invisible from both sides of the call: what we
    /// pass must sit INSIDE the models root, because its last component is
    /// thrown away. Passing the models root itself would land the files in a
    /// sibling of it.
    @Test func whatWePassSitsInsideTheModelsRoot() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url

        #expect(ParakeetModel.modelDirectory(in: root).deletingLastPathComponent().path == root.path)
        #expect(
            ParakeetModel.resolvedModelDirectory(in: root).deletingLastPathComponent().path
                == root.path
        )
    }

    /// The one that would catch an upstream rename: files placed at the
    /// literal resolved path must satisfy FluidAudio's own readiness check
    /// when it is asked about the directory we hand it.
    @Test func theLibraryFindsFilesAtTheResolvedPath() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url

        let resolved = root.appending(path: "parakeet-tdt-0.6b-v3", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        for name in Self.requiredFiles {
            try Data().write(to: resolved.appending(path: name))
        }

        #expect(
            AsrModels.modelsExist(
                at: ParakeetModel.modelDirectory(in: root),
                version: .v3,
                encoderPrecision: .int8
            )
        )
    }

    /// And the negative: an empty root is not ready, so readiness cannot be
    /// answered by the directory merely existing.
    @Test func anEmptyRootIsNotReady() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url

        #expect(
            AsrModels.modelsExist(
                at: ParakeetModel.modelDirectory(in: root),
                version: .v3,
                encoderPrecision: .int8
            ) == false
        )
    }

    /// `readyModelDirectory()` is a pure disk check and returns the directory
    /// the library is handed, not the resolved one — the pass forwards it
    /// straight back to `AsrModels.load`.
    @Test func readyModelDirectoryAnswersFromDiskAlone() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url

        let absent = ParakeetModel(modelsRoot: root)
        #expect(await absent.readyModelDirectory() == nil)

        let present = ParakeetModel(modelsRoot: root, modelsPresent: { true })
        #expect(await present.readyModelDirectory() == ParakeetModel.modelDirectory(in: root))
    }
}
