//
//  EchoPaths.swift
//  Echo
//
//  The single root for everything Echo writes to disk (user decision
//  2026-07-13): uninstalling the app must be "delete Echo.app + delete
//  ~/Library/Application Support/Echo". No UserDefaults, no ~/Documents,
//  no ad-hoc caches anywhere else.
//
//  SPEC-03 extends this enum with meetingsDirectory/knowledgeDirectory —
//  keep it an open namespace, one static per subdirectory.
//

import Foundation
import os

nonisolated enum EchoPaths {

    private static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "EchoPaths")

    /// ~/Library/Application Support/Echo
    static var appSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Echo", directoryHint: .isDirectory)
    }

    /// ~/Library/Application Support/Echo/Models — HubApi download base for
    /// every ML model the app fetches (summary LLM and WhisperKit models).
    /// Created on demand: the accessor is the only place that has to know the
    /// path, so it also guarantees existence (idempotent, cheap).
    static var modelsDirectory: URL {
        let url = appSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Legacy WhisperKit cache migration

    /// Repos that historically landed in swift-transformers' default download
    /// base (~/Documents/huggingface) before Echo pinned every download to
    /// `modelsDirectory`. Layout under both bases is `models/<org>/<repo>`,
    /// which is what HubApi expects — a plain move preserves it.
    private static let legacyHubRepoPaths = [
        "models/argmaxinc/whisperkit-coreml",
        "models/openai/whisper-large-v3",
    ]

    /// One-shot migration of the legacy WhisperKit cache into the single data
    /// root: moves (never copies — no re-download, no double disk) each known
    /// repo from ~/Documents/huggingface if it exists and the new location
    /// doesn't. Idempotent: after the first run both conditions fail. A failed
    /// move is logged and left in place — WhisperKit then just re-downloads
    /// into the new base, which is correct, only slower.
    static func migrateLegacyWhisperKitCacheIfNeeded() {
        let fm = FileManager.default
        let legacyBase = fm
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "huggingface", directoryHint: .isDirectory)
        let newBase = modelsDirectory

        for repoPath in legacyHubRepoPaths {
            let source = legacyBase.appending(path: repoPath)
            let destination = newBase.appending(path: repoPath)
            guard fm.fileExists(atPath: source.path),
                  !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.moveItem(at: source, to: destination)
                log.info("Migrated legacy model cache \(repoPath, privacy: .public) into Application Support/Echo/Models")
            } catch {
                log.error("Legacy cache migration failed for \(repoPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
