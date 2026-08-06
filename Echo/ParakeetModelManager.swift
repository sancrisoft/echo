//
//  ParakeetModelManager.swift
//  Echo
//
//  Owns the on-disk lifecycle of the ONE speech model Echo runs:
//  `parakeet-tdt-0.6b-v3` (NVIDIA, CC-BY-4.0), served through FluidAudio's
//  Core ML port. There is no live transcription any more — the single
//  transcript is produced post-meeting by `ParakeetPass` — so this manager
//  never gates recording (ADR-009 stays true by construction: nothing in the
//  record path consults it).
//
//  The discipline is the one every model manager here follows:
//  - Single data folder: every byte lands under `EchoPaths.modelsDirectory`.
//    FluidAudio resolves `download(to:)` / `load(from:)` / `modelsExist(at:)`
//    against `<parent-of-directory>/<repoFolderName>/`, so ONE constant —
//    `modelDirectory`, itself already ending in the repo folder name — is
//    passed everywhere and the files land exactly at
//    `…/Echo/Models/parakeet-tdt-0.6b-v3-coreml/`.
//  - Offline-first: readiness is a pure disk check, and FluidAudio's
//    `download` short-circuits on a complete cache — a launch with no network
//    never fails over files that are already there.
//  - Verify-before-ready: the transfer's return value is never trusted; the
//    files are re-checked on disk before the state flips to `ready`.
//  - Background, deferrable, once per launch: the fetch waits out an active
//    recording or a running pass instead of competing with them.
//

import FluidAudio
import Foundation
import os

/// Dashboard-facing lifecycle of the transcription model. Mirrors
/// `SummaryModelState`; `ready` means "complete model files on disk" — the
/// weights load pass-scoped inside `ParakeetPass`, never at rest.
enum ParakeetModelState: Equatable, Sendable {
    case absent
    case downloading(Double)   // fraction ∈ [0, 1], single source (ADR-007)
    case ready
    case failed(String)
}

/// Fetches the model files, reporting the running fraction. The real
/// implementation drives `AsrModels.download`; test fakes flip a flag.
typealias ParakeetModelDownloader =
    @Sendable (_ progress: @escaping @Sendable (Double) async -> Void) async throws -> Void

actor ParakeetModelManager {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "ParakeetModelManager")

    // MARK: - Identity

    /// The checkpoint id persisted into `TranscriptProvenance.modelName` — an
    /// on-disk contract, never a display string.
    static let modelID = "parakeet-tdt-0.6b-v3"
    /// Honest display strings for the models banner.
    static let modelDisplayName = "Parakeet v3 (0.6B)"
    static let modelDisplaySize = "~480 MB"
    /// CC-BY-4.0 requires attribution wherever the model is named.
    static let attribution = "Parakeet TDT 0.6B v3 © NVIDIA, CC-BY-4.0"

    static let version: AsrModelVersion = .v3
    static let encoderPrecision: ParakeetEncoderPrecision = .int8

    /// THE directory constant. Ends in FluidAudio's own repo folder name, so
    /// the library's `<parent>/<repoFolderName>` resolution lands the files
    /// right here instead of a sibling. Pass this — and only this — to
    /// `download`, `load`, and `modelsExist`.
    static var modelDirectory: URL {
        EchoPaths.modelsDirectory
            .appending(path: "parakeet-tdt-0.6b-v3-coreml", directoryHint: .isDirectory)
    }

    // MARK: - State

    private(set) var state: ParakeetModelState = .absent
    private var stateHandler: (@Sendable (ParakeetModelState) -> Void)?
    private var initializeStarted = false

    // Injectable seams (defaulted to the real disk / network), so the
    // lifecycle is testable without a 480 MB download.
    private let modelsPresent: @Sendable () -> Bool
    private let downloader: ParakeetModelDownloader
    private let deferPollInterval: Duration

    init(
        modelsPresent: @escaping @Sendable () -> Bool = ParakeetModelManager.liveModelsPresent,
        downloader: @escaping ParakeetModelDownloader = ParakeetModelManager.liveDownloader,
        deferPollInterval: Duration = .seconds(5)
    ) {
        self.modelsPresent = modelsPresent
        self.downloader = downloader
        self.deferPollInterval = deferPollInterval
    }

    /// Reports lifecycle transitions for the models banner. Late subscription
    /// reflects the current state immediately, so the row never sits on a
    /// stale placeholder.
    func setStateHandler(_ handler: @escaping @Sendable (ParakeetModelState) -> Void) {
        stateHandler = handler
        handler(state)
    }

    var currentState: ParakeetModelState { state }

    private func setState(_ new: ParakeetModelState) {
        state = new
        stateHandler?(new)
    }

    // MARK: - Per-pass query

    /// The model directory when a complete file set is on disk RIGHT NOW
    /// (re-checked per pass, offline), nil otherwise. Nil makes the pass throw
    /// `modelUnavailable`, which the coordinator treats as a failed attempt —
    /// the meeting stays pending and a later launch resumes it.
    func modelDirectoryIfReady() -> URL? {
        guard modelsPresent() else { return nil }
        return Self.modelDirectory
    }

    // MARK: - Background acquisition

    /// The lazy first-idle download. Idempotent per launch. `deferWhile` is
    /// polled until false before the transfer starts, so the fetch never
    /// competes with an active recording or a running pass. Never gates
    /// recording — a meeting recorded before this finishes simply stays
    /// pending until the model is ready.
    func initialize(deferWhile: @escaping @Sendable () async -> Bool = { false }) async {
        guard !initializeStarted else { return }
        initializeStarted = true

        if modelsPresent() {
            setState(.ready)
            return
        }
        setState(.absent)

        while await deferWhile() {
            try? await Task.sleep(for: deferPollInterval)
        }

        setState(.downloading(0))
        do {
            let downloader = self.downloader
            try await downloader { [weak self] fraction in
                await self?.noteDownloadProgress(fraction)
            }
            // Verify-before-ready, from disk: the transfer's return value is
            // never trusted.
            if modelsPresent() {
                setState(.ready)
                Self.log.info("Transcription model ready (\(Self.modelID, privacy: .public))")
            } else {
                setState(.failed("The downloaded model files did not pass verification. Relaunch to resume."))
                Self.log.error("Transcription model download finished but the files read incomplete")
            }
        } catch {
            setState(.failed(error.localizedDescription))
            ErrorTrace.record(
                "Transcription model download failed",
                error: error,
                category: "ParakeetModelManager"
            )
        }
    }

    private func noteDownloadProgress(_ fraction: Double) {
        // Only forward progress, and only while downloading: a stale Task-hop
        // straggler must neither rewind the bar nor resurrect a final state.
        guard case .downloading(let current) = state, fraction > current else { return }
        setState(.downloading(fraction))
    }

    // MARK: - Live seams

    /// The real offline readiness check — FluidAudio's own required-file list
    /// (models + vocabulary) against the same directory the download targets,
    /// so this answer can never drift from where the files actually go.
    static let liveModelsPresent: @Sendable () -> Bool = {
        AsrModels.modelsExist(
            at: modelDirectory,
            version: version,
            encoderPrecision: encoderPrecision
        )
    }

    /// The real download, pinned to the single data folder and wrapped in the
    /// app's stall watchdog (a connection that goes idle is cancelled and
    /// retried; FluidAudio skips files already committed, so a retry resumes).
    static let liveDownloader: ParakeetModelDownloader = { progress in
        _ = try await ModelDownload.withStallRetry(
            onRetry: { attempt in
                ParakeetModelManager.log.warning(
                    "Transcription model download stalled; retrying (attempt \(attempt, privacy: .public))"
                )
            }
        ) { noteProgress in
            try await AsrModels.download(
                to: modelDirectory,
                version: version,
                encoderPrecision: encoderPrecision
            ) { downloadProgress in
                let fraction = downloadProgress.fractionCompleted
                noteProgress(fraction)
                // FluidAudio's progress callbacks are synchronous; the async
                // hop is safe because the manager only ever moves the fraction
                // forward (`noteDownloadProgress`).
                Task { await progress(fraction) }
            }
        }
    }
}
