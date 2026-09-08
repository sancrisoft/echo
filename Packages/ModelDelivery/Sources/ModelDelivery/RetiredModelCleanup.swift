//
//  RetiredModelCleanup.swift
//  ModelDelivery
//
//  Launch-time reclamation of retired model snapshots. When the app swaps a
//  model — the summary model, or the whole speech stack — the old snapshot is
//  dead weight the updated build can never load. It is deleted at every
//  launch, immediately and unconditionally, so the disk is freed before (or
//  alongside) the new model's download on exactly the machines that need the
//  room.
//
//  The discipline, reused verbatim by every future migration (which only
//  appends to `retiredRepoIDs`, never edits the logic):
//  - Scoped by construction: a named-directory removal of exactly the retired
//    repo's directory. The models root is shared state (the speech model's
//    snapshot lives there today, an embeddings model's will) — never a sweep
//    of "everything that is not the current model".
//  - Non-fatal: a failed delete (file lock, permission) is traced and retried
//    on a later launch. Never a dialog, never an error surface, never a throw
//    out of `run`.
//  - Durable by repetition: runs on every launch; an already-absent directory
//    is a satisfied no-op, so no trigger state is persisted anywhere.
//

import EchoCore
import Foundation
import Hub
import os

public enum RetiredModelCleanup {

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "RetiredModelCleanup")

    /// Repo ids this app once downloaded and no longer uses. The next model
    /// migration extends this list; the deletion behavior stays untouched.
    public static let retiredRepoIDs = [
        // Retired 2026-07-28: the Gemma 4 12B summary model, replaced by the
        // 4B that shipped after it.
        "mlx-community/gemma-4-12B-it-qat-OptiQ-4bit",
        // Retired by the Parakeet migration (2026-08-06): the whole WhisperKit
        // repo — BOTH variants ever downloaded (the live turbo
        // `openai_whisper-large-v3-v20240930_626MB` and the final pass's
        // `openai_whisper-large-v3_947MB`, ~1.6 GB together) plus the folder
        // itself, which nothing else ever writes to. Scoped by construction:
        // the models root also holds `mlx-community/*` and the Parakeet
        // folder, and neither is named here.
        "argmaxinc/whisperkit-coreml",
        // ...and Whisper's tokenizer cache, fetched beside it.
        "openai/whisper-large-v3",
    ]

    /// Retired files that live directly under the models root rather than in a
    /// repo directory (same rules: named, idempotent, non-fatal).
    public static let retiredFileNames = [
        // The final pass's RAM-tiered snapshot manifest — the tier and the
        // model it vouched for both died with Whisper.
        "final-pass-model-manifest.json"
    ]

    /// Deletes every retired repo's directory and every retired loose file
    /// under `modelsRoot`.
    ///
    /// `modelsRoot` is required rather than defaulted to the real data root:
    /// library code that can reach the user's folder on its own is a test that
    /// can delete it by forgetting an argument. The composition root passes
    /// `dataRoot.models`.
    public static func run(
        retiredRepoIDs: [String] = retiredRepoIDs,
        retiredFileNames: [String] = retiredFileNames,
        modelsRoot: URL,
        remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        for fileName in retiredFileNames {
            let url = modelsRoot.appending(path: fileName, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try remove(url)
                log.info("Deleted retired model file \(fileName, privacy: .public)")
            } catch {
                ErrorTrace.record(
                    "Retired model cleanup failed",
                    error: error,
                    category: "RetiredModelCleanup",
                    metadata: ["file": fileName]
                )
            }
        }

        for repoID in retiredRepoIDs {
            // The same models/<org>/<repo> derivation the downloader uses for
            // its snapshot directory — going through the same API means the
            // cleanup's target can never drift from where the files actually
            // went.
            let directory = HubApi(downloadBase: modelsRoot, cache: nil)
                .localRepoLocation(HubApi.Repo(id: repoID))

            // Already gone — the obligation is satisfied (durable by
            // repetition, no persisted trigger state). Checked instead of
            // "attempt and swallow" so the post-migration steady state never
            // traces a spurious failure on every launch.
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }

            do {
                try remove(directory)
                log.info("Deleted retired model snapshot \(repoID, privacy: .public)")
            } catch {
                // Non-fatal by design: reclaiming disk is never worth an error
                // surface. The next launch's run is the retry.
                ErrorTrace.record(
                    "Retired model cleanup failed",
                    error: error,
                    category: "RetiredModelCleanup",
                    metadata: ["repo": repoID]
                )
            }
        }
    }
}
