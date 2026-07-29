//
//  SnapshotManifest.swift
//  Echo
//
//  The single source of truth for WHAT the summary model's snapshot is — the
//  file set — mirroring how ModelDownloadProgress is the single source for how
//  much of it exists (ADR-007/ADR-012). The manifest records the downloader's
//  actually-resolved file set at download time; "snapshot complete on disk"
//  is exactly "every manifest file committed in the snapshot directory".
//
//  Why not the repo's sharding index: the index is an artifact of sharding,
//  not a manifest of what Echo fetches. The Qwen repo's index references a
//  vision sidecar (optiq/optiq_vision.safetensors) that the download globs
//  deliberately exclude, so an index-derived rule reads a COMPLETE snapshot
//  as forever-incomplete — and a single-file repo may ship no index at all.
//  Deriving from the downloader's own resolution is layout-agnostic and
//  survives model swaps with no edits here.
//
//  Failure is safe in one direction only (ADR-012): a missing, unreadable, or
//  foreign-model manifest reads as INCOMPLETE — routing to the resume path,
//  which no-ops per already-committed file — never as ready. The check
//  answers offline: it touches only local files.
//
//  Pure decision on purpose: directory and manifest location are inputs, so
//  completeness is table-testable against synthetic layouts with no network
//  and no real models root (SP-004 Testing Decisions, layer 2).
//

import Foundation

/// The locally-recorded file set that makes one model's snapshot complete.
nonisolated struct SnapshotManifest: Codable, Equatable, Sendable {

    /// The repo id whose download resolved `files`. A manifest can only ever
    /// validate the model it was written for — a stale record from a retired
    /// model must read as "no manifest" (incomplete), not vouch for the new
    /// snapshot (ADR-012's invalidated-with-the-model-id requirement).
    let modelID: String

    /// Repo-relative paths of every file the snapshot download resolved —
    /// weights, configs, tokenizer artifacts alike, whatever the layout.
    let files: [String]

    // MARK: - Persistence

    /// Reads a manifest, or nil when the file is missing or unreadable — the
    /// fail-safe direction: no manifest, no completeness claim.
    static func read(from url: URL) -> SnapshotManifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(SnapshotManifest.self, from: data)
        else { return nil }
        return manifest
    }

    /// Atomic write (never a torn read for a concurrent completeness check);
    /// creates the parent directory on first write, mirroring
    /// FileDownloadPauseStore.
    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - The completeness verdict

    /// Whether `directory` holds a complete snapshot for `modelID`: the
    /// manifest at `manifestURL` exists, and every file it records is
    /// committed on disk.
    static func snapshotComplete(
        forModelID modelID: String,
        in directory: URL,
        manifestAt manifestURL: URL
    ) -> Bool {
        guard let manifest = read(from: manifestURL) else { return false }
        // Scoping: a record written for another model (a retired one, or a
        // sibling build's) never validates this snapshot — it reads exactly
        // like no manifest at all.
        guard manifest.modelID == modelID else { return false }
        return manifest.allFilesCommitted(in: directory)
    }

    /// Every recorded file exists committed in `directory` — real files,
    /// re-checked every time: a transfer's return value is never trusted (an
    /// interrupted download's stale staging metadata once let a snapshot
    /// pass "succeed" with tokenizer.json still missing). Also the
    /// downloader's verify-before-record step, so a manifest is only ever
    /// written over a snapshot it actually describes.
    func allFilesCommitted(in directory: URL) -> Bool {
        // An empty file set would make the loop below vacuously true — a
        // false "ready" over a record that vouches for nothing. Fail safe.
        guard !files.isEmpty else { return false }
        let fm = FileManager.default
        for file in files {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory.appending(path: file).path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return false }
        }
        return true
    }
}
