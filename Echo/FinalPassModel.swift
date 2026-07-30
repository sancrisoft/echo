//
//  FinalPassModel.swift
//  Echo
//
//  SP-005 S5 (ADR-015): the final pass's RAM-tiered model. Machines in the
//  16 GB class run the pass on the full-decoder `openai_whisper-large-v3_947MB`
//  checkpoint — loaded for the pass only, released after — while the 8 GB
//  floor (and every degraded case: snapshot absent, still downloading, load
//  failed) reuses the already-loaded live model through
//  `LivePipelineModelProvider`. The tiered model is optional by construction:
//  it never gates recording (ADR-009 untouched), never blocks or errors a
//  meeting, and its download runs in the background behind the record-gating
//  speech model and the summary model.
//
//  Snapshot completeness is manifest-derived (ADR-012 register, applied to the
//  WhisperKit repo layout): the manifest records the repo's own resolution for
//  the variant — every file WhisperKit's download glob fetches, with its
//  committed on-disk size — so the answer is offline, layout-agnostic (no
//  hardcoded four-file list, the pre-ADR-012 `cachedModelFolder` mistake), and
//  fails toward "incomplete" in every doubtful direction.
//

import Foundation
import WhisperKit
import os

// MARK: - RAM tier (pure — SP-005 Testing Decisions, layer 1)

/// Which model class the final pass runs on, decided purely by physical RAM
/// (ADR-015: no user-facing picker in v1; the tier decides).
nonisolated enum FinalPassTier: Equatable, Sendable {
    /// Below the 16 GB class: the pass reuses the already-loaded live model —
    /// zero additional model memory, the universal floor.
    case reuseLive
    /// 16 GB class and above: the pass loads the full-decoder 947 MB
    /// checkpoint for its own duration and releases it when it completes.
    case fullLargeV3

    /// The 16 GB-class threshold, with tolerance for marketing-vs-reported
    /// sizes: `ProcessInfo.physicalMemory` on a machine sold as "16 GB" can
    /// come in under a literal 16 GiB (firmware/hypervisor carve-outs), so a
    /// 16-GiB-exact threshold would misclassify real 16 GB machines as the
    /// floor tier. Anything at or above 15.0 GiB is unambiguously the 16 GB
    /// class — the nearest configurations below are 8 and 12 GB, both far
    /// under the line even with generous reporting slack.
    static let fullTierMinimumBytes: UInt64 = 15 * 1_073_741_824

    static func tier(forPhysicalMemory bytes: UInt64) -> FinalPassTier {
        bytes >= fullTierMinimumBytes ? .fullLargeV3 : .reuseLive
    }

    /// This machine's tier. Pure over `physicalMemory`, which never changes
    /// within a process — "decided per pass" and "decided at launch" agree.
    static var current: FinalPassTier {
        tier(forPhysicalMemory: ProcessInfo.processInfo.physicalMemory)
    }
}

// MARK: - Snapshot completeness manifest (ADR-012, WhisperKit repo layout)

/// The locally-recorded file set (with sizes) that makes the final-pass
/// model's snapshot complete. Mirrors `SnapshotManifest` (the summary model's
/// record) with two layout adaptations for the WhisperKit repo: paths are
/// repo-relative (the variant folder plus the compiled `.mlmodelc` trees
/// inside it), and each file's committed size is recorded — a truncated
/// weight blob inside an `.mlmodelc` bundle would otherwise read "present".
nonisolated struct FinalPassSnapshotManifest: Codable, Equatable, Sendable {

    struct FileRecord: Codable, Equatable, Sendable {
        /// Repo-relative path, e.g.
        /// "openai_whisper-large-v3_947MB/TextDecoder.mlmodelc/weights/weight.bin".
        let path: String
        /// The file's size when the download committed it.
        let size: Int64
    }

    /// The variant folder this record vouches for. A stale record from
    /// another variant must read as "no manifest" (incomplete), never vouch
    /// for this snapshot (ADR-012's invalidated-with-the-model-id rule).
    let variantFolder: String

    let files: [FileRecord]

    // MARK: Persistence

    /// Reads a manifest, or nil when missing/unreadable — the fail-safe
    /// direction: no manifest, no completeness claim.
    static func read(from url: URL) -> FinalPassSnapshotManifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(FinalPassSnapshotManifest.self, from: data)
        else { return nil }
        return manifest
    }

    /// Atomic write (never a torn read for a concurrent completeness check);
    /// creates the parent directory on first write, like `SnapshotManifest`.
    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    // MARK: The completeness verdict

    /// Whether `repoDirectory` holds a complete snapshot for `variantFolder`:
    /// the manifest exists, was written for this variant, and every file it
    /// records is committed on disk at its recorded size. Offline — local
    /// files only.
    static func snapshotComplete(
        forVariantFolder variantFolder: String,
        in repoDirectory: URL,
        manifestAt manifestURL: URL
    ) -> Bool {
        guard let manifest = read(from: manifestURL) else { return false }
        guard manifest.variantFolder == variantFolder else { return false }
        return manifest.allFilesCommitted(in: repoDirectory)
    }

    /// Every recorded file exists committed in `repoDirectory` at its
    /// recorded size — real files re-checked every time (a transfer's return
    /// value is never trusted; the SnapshotManifest register).
    func allFilesCommitted(in repoDirectory: URL) -> Bool {
        // An empty file set would make the loop vacuously true — a false
        // "ready" over a record that vouches for nothing. Fail safe.
        guard !files.isEmpty else { return false }
        let fm = FileManager.default
        for record in files {
            let url = repoDirectory.appending(path: record.path)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize,
                  Int64(size) == record.size
            else { return false }
        }
        return true
    }
}

// MARK: - Lifecycle state (for the UI slice)

/// Dashboard-facing lifecycle of the optional final-pass model. Mirrors
/// `SpeechModelState`/`SummaryModelState`; `ready` means "complete snapshot on
/// disk" — the weights load pass-scoped, never at rest (ADR-015).
enum FinalPassModelState: Equatable, Sendable {
    /// This machine's tier never uses the 947 MB model — no download will
    /// ever be needed (carries the tier so the UI can say why).
    case notNeeded(FinalPassTier)
    case absent
    case downloading(Double)   // fraction ∈ [0, 1], single source (ADR-007)
    case ready
    case failed(String)
}

/// Downloads the 947 MB snapshot, reporting the running fraction. The real
/// implementation drives `WhisperKit.download` with stall-retry and records
/// the completeness manifest on success; test fakes flip a flag.
typealias FinalPassModelDownloader =
    @Sendable (_ progress: @escaping @Sendable (Double) async -> Void) async throws -> Void

// MARK: - Acquisition manager

/// Owns the final-pass model's on-disk lifecycle: tier decision, offline
/// completeness, background download. Never touches recording readiness
/// (ADR-009) and never loads weights — `TieredFinalPassModelProvider` does
/// that, pass-scoped. Seams are injectable (SummaryModelManager's pattern) so
/// the lifecycle tests run without network, disk, or a 947 MB model.
actor FinalPassModelManager {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "FinalPassModelManager")

    /// WhisperKit variant suffix; the repo folder is "openai_whisper-" + this.
    static let variant = "large-v3_947MB"
    static let variantFolderName = "openai_whisper-large-v3_947MB"
    static let repoID = "argmaxinc/whisperkit-coreml"
    /// Honest display strings for the models banner (SP-005 honest surfaces):
    /// this one really is the full large-v3 decoder, unlike the live turbo.
    static let modelDisplayName = "Whisper large-v3 (full)"
    static let modelDisplaySize = "947 MB"

    /// The WhisperKit repo under the SAME models root the live model uses.
    static var repoDirectory: URL {
        EchoPaths.modelsDirectory.appending(path: "models/\(repoID)", directoryHint: .isDirectory)
    }

    static var variantDirectory: URL {
        repoDirectory.appending(path: variantFolderName, directoryHint: .isDirectory)
    }

    /// Beside the models tree, NOT inside the Hub-managed repo directory —
    /// a foreign JSON planted there would poison HubApi's offline snapshot
    /// validation (the summary manifest's placement rationale, verbatim).
    static var manifestFileURL: URL {
        EchoPaths.modelsDirectory
            .appending(path: "final-pass-model-manifest.json", directoryHint: .notDirectory)
    }

    // MARK: State

    private(set) var state: FinalPassModelState
    private var stateHandler: (@Sendable (FinalPassModelState) -> Void)?
    private var initializeStarted = false

    // Injectable seams (defaulted to the real tier / disk / network).
    private let tier: FinalPassTier
    private let snapshotComplete: @Sendable () -> Bool
    private let downloader: FinalPassModelDownloader
    private let deferPollInterval: Duration

    init(
        tier: FinalPassTier = .current,
        snapshotComplete: @escaping @Sendable () -> Bool = FinalPassModelManager.liveSnapshotComplete,
        downloader: @escaping FinalPassModelDownloader = FinalPassModelManager.liveDownloader,
        deferPollInterval: Duration = .seconds(5)
    ) {
        self.tier = tier
        self.snapshotComplete = snapshotComplete
        self.downloader = downloader
        self.deferPollInterval = deferPollInterval
        self.state = tier == .fullLargeV3 ? .absent : .notNeeded(tier)
    }

    /// Reports lifecycle transitions for the UI slice's models banner. Late
    /// subscription reflects the current state immediately (the pipeline's
    /// phase-handler discipline).
    func setStateHandler(_ handler: @escaping @Sendable (FinalPassModelState) -> Void) {
        stateHandler = handler
        handler(state)
    }

    var currentState: FinalPassModelState { state }

    private func setState(_ new: FinalPassModelState) {
        state = new
        stateHandler?(new)
    }

    // MARK: Per-pass query

    /// Lends the snapshot folder when — and only when — this machine's tier
    /// wants the 947 MB model AND a complete snapshot is on disk right now
    /// (re-checked per pass, offline). Nil routes the pass to the live model.
    func passModelFolderIfReady() -> URL? {
        guard tier == .fullLargeV3, snapshotComplete() else { return nil }
        return Self.variantDirectory
    }

    // MARK: Background acquisition

    /// The lazy first-idle trigger (ADR-015): on a `.fullLargeV3` machine
    /// with no complete snapshot, downloads it in the background. Idempotent
    /// per launch. `deferWhile` is the simple sequencing guard — polled until
    /// false before the transfer starts, so the fetch never competes with an
    /// active recording (the caller already sequences it behind the speech
    /// and summary downloads; S4's admission machine supersedes this later).
    func initialize(deferWhile: @escaping @Sendable () async -> Bool = { false }) async {
        guard !initializeStarted else { return }
        initializeStarted = true

        guard tier == .fullLargeV3 else {
            setState(.notNeeded(tier))
            return
        }
        if snapshotComplete() {
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
            // never trusted (ADR-012 fail-safe direction).
            if snapshotComplete() {
                setState(.ready)
                Self.log.info("Final-pass model snapshot ready (\(Self.variantFolderName, privacy: .public))")
            } else {
                setState(.failed("The downloaded model files did not pass verification. Relaunch to resume."))
                Self.log.error("Final-pass model download finished but the snapshot reads incomplete")
            }
        } catch {
            setState(.failed(error.localizedDescription))
            Self.log.error("Final-pass model download failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func noteDownloadProgress(_ fraction: Double) {
        // Only forward progress, and only while downloading: a stale Task-hop
        // straggler must neither rewind the bar nor resurrect a final state.
        guard case .downloading(let current) = state, fraction > current else { return }
        setState(.downloading(fraction))
    }

    // MARK: Live seams

    /// The real offline completeness check: manifest ∧ files-at-size on disk
    /// (ADR-012 applied to the WhisperKit repo layout).
    static let liveSnapshotComplete: @Sendable () -> Bool = {
        FinalPassSnapshotManifest.snapshotComplete(
            forVariantFolder: variantFolderName,
            in: repoDirectory,
            manifestAt: manifestFileURL
        )
    }

    /// The real download: the same WhisperKit/Hub machinery (and stall-retry)
    /// the live speech model uses, pinned to the same models root; then the
    /// completeness manifest, recorded from the repo's own resolution for the
    /// variant — the exact glob `WhisperKit.download` fetches with — with each
    /// file verified committed on disk (sizes captured) before the record is
    /// written. No manifest is ever recorded over a transfer that didn't
    /// genuinely complete.
    static let liveDownloader: FinalPassModelDownloader = { progress in
        _ = try await ModelDownload.withStallRetry(
            onRetry: { attempt in
                FinalPassModelManager.log.warning(
                    "Final-pass model download stalled; retrying (attempt \(attempt, privacy: .public))"
                )
            }
        ) { noteProgress in
            try await WhisperKit.download(
                variant: FinalPassModelManager.variant,
                downloadBase: EchoPaths.modelsDirectory,
                useBackgroundSession: false
            ) { p in
                let fraction = p.fractionCompleted
                noteProgress(fraction)
                // Hub progress callbacks are synchronous; the async hop is
                // safe because the manager only ever moves the fraction
                // forward (`noteDownloadProgress`).
                Task { await progress(fraction) }
            }
        }

        let hub = HubApiWrapper(downloadBase: EchoPaths.modelsDirectory)
        let repo = HubApiWrapper.Repo(id: FinalPassModelManager.repoID)
        let resolved = try await hub.getFilenames(
            from: repo,
            matching: ["*\(FinalPassModelManager.variant)/*"]
        )
        let variantFiles = resolved.filter {
            $0.hasPrefix("\(FinalPassModelManager.variantFolderName)/")
        }
        guard !variantFiles.isEmpty else { throw FinalPassModelError.verificationFailed }

        var records: [FinalPassSnapshotManifest.FileRecord] = []
        for path in variantFiles.sorted() {
            let url = FinalPassModelManager.repoDirectory.appending(path: path)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { throw FinalPassModelError.verificationFailed }
            records.append(.init(path: path, size: Int64(size)))
        }
        try FinalPassSnapshotManifest(
            variantFolder: FinalPassModelManager.variantFolderName,
            files: records
        ).write(to: FinalPassModelManager.manifestFileURL)
    }
}

nonisolated enum FinalPassModelError: LocalizedError {
    /// The transfer returned but a repo-resolved file is missing on disk —
    /// no manifest is recorded, completeness stays honestly incomplete, and a
    /// retry resumes cheaply (the Hub skips files already committed).
    case verificationFailed

    var errorDescription: String? {
        "The downloaded model files did not pass verification. Retry to resume the download."
    }
}

// MARK: - Tiered provider (the FinalizationPass seam)

/// Which model actually served a final pass — surfaced so the UI slice can
/// say so honestly ("finalized on large-v3" vs "finalized on the live model").
nonisolated enum FinalPassModelChoice: Equatable, Sendable {
    case fullLargeV3
    case liveModel
}

/// ADR-015 behind the `FinalPassModelProviding` seam: per pass, tier
/// `.fullLargeV3` with a complete snapshot loads a pass-scoped WhisperKit
/// instance (released when the pass completes); every other case — floor
/// tier, snapshot absent/incomplete/downloading, load failure — delegates to
/// the live model. Automatic, never blocking, never erroring a meeting for
/// model-availability reasons.
actor TieredFinalPassModelProvider: FinalPassModelProviding {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "TieredFinalPassModelProvider")

    typealias PassModelLoader = @Sendable (URL) async throws -> WhisperKit

    /// The pure per-pass decision (SP-005 Testing Decisions layer 1's
    /// fallback rows): every doubt routes to the live model.
    static func decide(
        tier: FinalPassTier,
        snapshotComplete: Bool,
        loadFailedThisSession: Bool
    ) -> FinalPassModelChoice {
        guard tier == .fullLargeV3, snapshotComplete, !loadFailedThisSession else {
            return .liveModel
        }
        return .fullLargeV3
    }

    private let tierProvider: @Sendable () -> FinalPassTier
    /// The snapshot folder when complete on disk, nil otherwise — the
    /// completeness input, re-queried per pass (offline).
    private let readyFolder: @Sendable () async -> URL?
    private let loadModel: PassModelLoader
    private let fallback: any FinalPassModelProviding
    private let onServed: (@Sendable (FinalPassModelChoice) -> Void)?

    /// A load failure is remembered for the session: one broken snapshot must
    /// not retry-loop across a pass's windows (or across passes this launch).
    /// A relaunch — or a re-download fixing the snapshot — clears it.
    private var loadFailedThisSession = false

    /// The model that served the most recent `withModel` call.
    private(set) var lastServed: FinalPassModelChoice?

    init(
        tierProvider: @escaping @Sendable () -> FinalPassTier,
        readyFolder: @escaping @Sendable () async -> URL?,
        loadModel: @escaping PassModelLoader,
        fallback: any FinalPassModelProviding,
        onServed: (@Sendable (FinalPassModelChoice) -> Void)? = nil
    ) {
        self.tierProvider = tierProvider
        self.readyFolder = readyFolder
        self.loadModel = loadModel
        self.fallback = fallback
        self.onServed = onServed
    }

    /// Production wiring: tier from this machine's RAM, completeness from the
    /// manager's offline check, real WhisperKit load.
    init(
        manager: FinalPassModelManager,
        fallback: any FinalPassModelProviding,
        onServed: (@Sendable (FinalPassModelChoice) -> Void)? = nil
    ) {
        self.tierProvider = { FinalPassTier.current }
        self.readyFolder = { await manager.passModelFolderIfReady() }
        self.loadModel = Self.livePassModelLoader
        self.fallback = fallback
        self.onServed = onServed
    }

    func withModel<T: Sendable>(
        _ body: @Sendable (WhisperKit) async throws -> T
    ) async throws -> T {
        let folder = await readyFolder()
        let choice = Self.decide(
            tier: tierProvider(),
            snapshotComplete: folder != nil,
            loadFailedThisSession: loadFailedThisSession
        )
        guard choice == .fullLargeV3, let folder else {
            return try await serveLive(body)
        }

        let whisper: WhisperKit
        do {
            whisper = try await loadModel(folder)
        } catch {
            // Graceful floor (ADR-015): a failed load degrades to the live
            // model — never a blocked or errored meeting.
            loadFailedThisSession = true
            Self.log.error("""
            Final-pass model load failed — falling back to the live model: \
            \(error.localizedDescription, privacy: .public)
            """)
            return try await serveLive(body)
        }

        serve(.fullLargeV3)
        do {
            let result = try await body(whisper)
            await release(whisper)
            return result
        } catch {
            // A decode failure is the PASS failing, not a model-availability
            // problem: release and rethrow — the caller's live-transcript
            // floor owns it. Never silently re-decode on the live model.
            await release(whisper)
            throw error
        }
    }

    private func serveLive<T: Sendable>(
        _ body: @Sendable (WhisperKit) async throws -> T
    ) async throws -> T {
        serve(.liveModel)
        return try await fallback.withModel(body)
    }

    private func serve(_ choice: FinalPassModelChoice) {
        lastServed = choice
        onServed?(choice)
    }

    /// Pass-scoped release: `unloadModels()` drops the compiled Core ML
    /// models eagerly; the instance itself (tokenizer, buffers) frees when
    /// the last reference — the caller's local — goes out of scope. WhisperKit
    /// exposes no further teardown API, and none is needed.
    private func release(_ whisper: WhisperKit) async {
        await whisper.unloadModels()
    }

    /// The real pass-scoped load: same construction as the live pipeline's
    /// (prewarm false, load true; `download: true` only lets the tokenizer
    /// resolve if it isn't cached yet, pinned under the same models root).
    static let livePassModelLoader: PassModelLoader = { folder in
        try await WhisperKit(
            modelFolder: folder.path,
            tokenizerFolder: EchoPaths.modelsDirectory,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: true
        )
    }
}
