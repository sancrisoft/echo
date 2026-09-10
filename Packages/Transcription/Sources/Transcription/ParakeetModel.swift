//
//  ParakeetModel.swift
//  Transcription
//
//  Owns the on-disk lifecycle of the ONE speech model Echo runs:
//  `parakeet-tdt-0.6b-v3` (NVIDIA, CC-BY-4.0), served through FluidAudio's
//  Core ML port. There is no live transcription — the single transcript is
//  produced post-meeting by `TranscriptionPass` — so this model never gates
//  recording: nothing in the record path consults it.
//
//  The discipline every model owner here follows:
//  - Single data folder: every byte lands under the injected models root.
//    FluidAudio does not use the directory it is handed as-is: `download(to:)`,
//    `load(from:)` and `modelsExist(at:)` all discard its LAST component and
//    append their own `Repo.folderName`. For v3 that name is
//    `parakeet-tdt-0.6b-v3` — the Hugging Face repo slug with `-coreml`
//    stripped by a `default` branch — so the files land in
//    `…/Echo/Models/parakeet-tdt-0.6b-v3/`, which is where a v1 install
//    already has them. Only the PARENT of `modelDirectory` is load-bearing;
//    its own last component is a placeholder that never exists on disk. One
//    constant is still passed everywhere, so the offline check and the
//    download can never disagree about where the files are.
//
//    The invariant that follows is not obvious from either side of the call:
//    the argument must be a path INSIDE the models directory, whatever its
//    last component is named. Passing the models directory itself is the
//    tempting simplification ("why hand it a folder that does not exist?")
//    and it is silently wrong — there is no component to discard, so the
//    parent becomes the data root and the bytes land in a sibling of
//    `Models/`, re-downloading 480 MB on every launch while the real
//    snapshot sits untouched next door.
//  - Offline-first: readiness is a pure disk check, and FluidAudio's
//    `download` short-circuits on a complete cache — a launch with no network
//    never fails over files that are already there. An expired Hugging Face
//    token once killed model loads silently, with no error and no model; the
//    fix was to stop reaching for the network when the cache is complete.
//  - Verify-before-ready: the transfer's return value is never trusted; the
//    files are re-checked on disk before the state flips to `ready`.
//  - Background, deferrable, once per launch: the fetch waits out an active
//    recording or a running pass instead of competing with them.
//

import EchoCore
import FluidAudio
import Foundation
import ModelDelivery
import os

/// Lifecycle of the transcription model. `ready` means "complete model files
/// on disk" — the weights load pass-scoped inside `TranscriptionPass`, never
/// at rest.
public enum ParakeetModelState: Equatable, Sendable {
    case absent
    /// Fraction ∈ [0, 1], one clamped source.
    case downloading(Double)
    case ready
    case failed(String)
}

/// Fetches the model files, reporting the running fraction. The real
/// implementation drives `AsrModels.download`; test fakes flip a flag.
public typealias ParakeetModelDownloader =
    @Sendable (_ progress: @escaping @Sendable (Double) async -> Void) async throws -> Void

public actor ParakeetModel {

    static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "ParakeetModel")

    // MARK: - Identity

    /// The checkpoint id persisted into a meeting's transcript provenance —
    /// an on-disk contract, never a display string.
    public static let modelID = "parakeet-tdt-0.6b-v3"
    /// Honest display strings for the models banner.
    public static let modelDisplayName = "Parakeet v3 (0.6B)"
    public static let modelDisplaySize = "~480 MB"
    /// CC-BY-4.0 requires attribution wherever the model is named.
    public static let attribution = "Parakeet TDT 0.6B v3 © NVIDIA, CC-BY-4.0"

    static let version: AsrModelVersion = .v3
    static let encoderPrecision: ParakeetEncoderPrecision = .int8

    /// The Hugging Face repo slug. Carried verbatim from v1 because FluidAudio
    /// throws this component away (see the header) and only the parent it
    /// leaves behind decides where the files go — changing the literal would
    /// move nothing, and keeping it documents which checkpoint is meant.
    static let repoSlug = "parakeet-tdt-0.6b-v3-coreml"

    /// The directory FluidAudio's own resolution actually reads and writes,
    /// derived the way the library derives it. `modelDirectory` is what the
    /// library is handed; this is where the bytes end up, and the two differ.
    static let resolvedFolderName = "parakeet-tdt-0.6b-v3"

    /// THE directory constant. Pass this — and only this — to `download`,
    /// `load` and `modelsExist`, so all three resolve to the same place.
    public static func modelDirectory(in modelsRoot: URL) -> URL {
        modelsRoot.appending(path: repoSlug, directoryHint: .isDirectory)
    }

    /// Where the model files actually live under `modelsRoot`. Not passed to
    /// FluidAudio — it is for callers that need to look, and for the test that
    /// pins the library's resolution so an upstream change to `folderName`
    /// fails here instead of silently re-downloading 480 MB on every launch.
    public static func resolvedModelDirectory(in modelsRoot: URL) -> URL {
        modelsRoot.appending(path: resolvedFolderName, directoryHint: .isDirectory)
    }

    // MARK: - State

    public private(set) var state: ParakeetModelState = .absent

    private let modelsRoot: URL
    private var initializeStarted = false

    // Injectable seams (defaulted to the real disk / network), so the
    // lifecycle is testable without a 480 MB download.
    private let modelsPresent: @Sendable () -> Bool
    private let downloader: ParakeetModelDownloader
    private let deferPollInterval: Duration

    public init(
        modelsRoot: URL,
        modelsPresent: (@Sendable () -> Bool)? = nil,
        downloader: ParakeetModelDownloader? = nil,
        deferPollInterval: Duration = .seconds(5)
    ) {
        self.modelsRoot = modelsRoot
        let directory = Self.modelDirectory(in: modelsRoot)
        self.modelsPresent = modelsPresent ?? { Self.liveModelsPresent(at: directory) }
        self.downloader =
            downloader ?? { progress in
                try await Self.liveDownload(to: directory, progress: progress)
            }
        self.deferPollInterval = deferPollInterval
    }

    // MARK: - Per-pass query

    /// The model directory when a complete file set is on disk RIGHT NOW
    /// (re-checked per pass, offline), nil otherwise. Nil makes the pass throw
    /// `modelUnavailable`, which the coordinator treats as a failed attempt —
    /// the meeting stays pending and a later launch resumes it.
    public func readyModelDirectory() -> URL? {
        guard modelsPresent() else { return nil }
        return Self.modelDirectory(in: modelsRoot)
    }

    // MARK: - Background acquisition

    /// The lazy first-idle download. Idempotent per launch. `deferWhile` is
    /// polled until false before the transfer starts, so the fetch never
    /// competes with an active recording or a running pass. Never gates
    /// recording — a meeting recorded before this finishes simply stays
    /// pending until the model is ready.
    public func initialize(deferWhile: @escaping @Sendable () async -> Bool = { false }) async {
        guard !initializeStarted else { return }
        initializeStarted = true

        if modelsPresent() {
            state = .ready
            return
        }
        state = .absent

        while await deferWhile() {
            // Cancellation ends the wait instead of spinning it: `try?` here
            // swallowed the cancellation and turned the poll into a busy loop.
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: deferPollInterval)
            } catch {
                return
            }
        }

        state = .downloading(0)
        do {
            let downloader = self.downloader
            try await downloader { [weak self] fraction in
                await self?.noteDownloadProgress(fraction)
            }
            // Verify-before-ready, from disk: the transfer's return value is
            // never trusted.
            if modelsPresent() {
                state = .ready
                Self.log.info("Transcription model ready (\(Self.modelID, privacy: .public))")
            } else {
                state = .failed("The downloaded model files did not pass verification. Relaunch to resume.")
                Self.log.error("Transcription model download finished but the files read incomplete")
            }
        } catch {
            state = .failed(error.localizedDescription)
            ErrorTrace.record(
                "Transcription model download failed",
                error: error,
                category: "ParakeetModel"
            )
        }
    }

    private func noteDownloadProgress(_ fraction: Double) {
        // Only forward progress, and only while downloading: a stale Task-hop
        // straggler must neither rewind the bar nor resurrect a final state.
        guard case .downloading(let current) = state, fraction > current else { return }
        state = .downloading(fraction)
    }

    // MARK: - Live seams

    /// The real offline readiness check — FluidAudio's own required-file list
    /// (models + vocabulary) against the same directory the download targets,
    /// so this answer can never drift from where the files actually go.
    static func liveModelsPresent(at directory: URL) -> Bool {
        AsrModels.modelsExist(
            at: directory,
            version: version,
            encoderPrecision: encoderPrecision
        )
    }

    /// The real download, pinned to the single data folder and wrapped in the
    /// app's stall watchdog (a connection that goes idle is cancelled and
    /// retried; FluidAudio skips files already committed, so a retry resumes).
    ///
    /// The watchdog measures OUR heartbeat, so `noteProgress` must be fed
    /// FluidAudio's fraction and nothing synthetic. That fraction is
    /// byte-weighted whenever the listing carries file sizes, and falls back
    /// to a per-file count only when it does not — the one case where a slow
    /// link could look idle for the full `stallTimeout` on a healthy transfer.
    /// The defaults are carried from the measurement that set them; changing
    /// them needs a new one.
    ///
    /// A second latent case, harmless today: `AsrModels.download` calls into
    /// FluidAudio once per model file, the first call fetches the whole repo
    /// and the rest are cache hits, and each call restarts its own fraction
    /// part-way. Those restarts are correctly ignored (only strictly forward
    /// progress resets the clock), which means the heartbeat does not advance
    /// during them at all. They are Core ML compiles measured in milliseconds;
    /// if a future checkpoint ever made one exceed the stall timeout, a
    /// finished download would report a stall.
    static func liveDownload(
        to directory: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        _ = try await DownloadRetry.withStallRetry(
            onRetry: { attempt in
                log.warning(
                    "Transcription model download stalled; retrying (attempt \(attempt, privacy: .public))"
                )
            },
            operation: { noteProgress in
                try await AsrModels.download(
                    to: directory,
                    version: version,
                    encoderPrecision: encoderPrecision,
                    progressHandler: { downloadProgress in
                        let fraction = downloadProgress.fractionCompleted
                        noteProgress(fraction)
                        // FluidAudio's progress callbacks are synchronous; the
                        // async hop is safe because the model only ever moves
                        // the fraction forward (`noteDownloadProgress`).
                        Task { await progress(fraction) }
                    }
                )
            }
        )
    }
}
