//
//  MeetingLibrary.swift
//  Echo
//
//  Main-actor, observable façade over `MeetingStore` for the dashboard (SPEC-03,
//  extended for the meeting-library redesign). It owns the split the UI reads:
//  the live meetings ("All Meetings"), the trashed ones ("Trash", auto-purged
//  after a retention window), the current selection, and which meeting (if any)
//  is currently backed by the live session's in-memory state.
//

import Foundation
import Observation

/// What the sidebar has selected. `.live` is the pinned "recording in progress"
/// row (only present while recording); `.meeting` is a saved meeting.
enum MeetingSelection: Hashable, Sendable {
    case live
    case meeting(UUID)
}

/// The library's two top-level views, bound to the sidebar.
enum LibrarySection: Hashable, Sendable {
    case all
    case trash
}

@Observable
@MainActor
final class MeetingLibrary {

    /// A meeting sits in Trash for this long before it is permanently removed.
    static let trashRetention: TimeInterval = 30 * 24 * 60 * 60   // 30 days

    private let store: MeetingStore

    /// Live meetings (not trashed), newest first. Refreshed after each write.
    private(set) var metas: [MeetingMeta] = []

    /// Trashed meetings, most-recently-trashed first.
    private(set) var trashedMetas: [MeetingMeta] = []

    /// Total bytes the meeting library occupies on disk (transcripts,
    /// summaries, sidecars — NOT the AI models), shown in the sidebar footer.
    /// `nil` until the first background measurement lands.
    private(set) var storageBytes: Int64?

    /// Which top-level view the sidebar shows.
    var section: LibrarySection = .all

    /// The sidebar's current selection (bound by the List).
    var selection: MeetingSelection?

    /// The meeting whose transcript/summary is currently the *live* in-memory
    /// state on `RecordingState` (the just-stopped session, until the next
    /// recording wipes that state). While it equals the selected meeting, the
    /// detail view keeps showing the live state — so a summary can stream into
    /// the just-saved meeting's detail with no jump — instead of reloading the
    /// still-summary-less record from disk.
    private(set) var activeMeetingID: UUID?

    /// Guards against overlapping word-count backfills.
    private var isBackfilling = false

    init(store: MeetingStore = MeetingStore()) {
        self.store = store
        Task { await refresh() }
    }

    // MARK: - Sidecar contract (reveal / export)

    /// The on-disk folder for a meeting. `nonisolated` passthrough to the store
    /// so callers (Reveal in Finder, Export) can locate the folder without
    /// awaiting the actor.
    nonisolated func directory(for id: UUID) -> URL {
        store.directory(for: id)
    }

    // MARK: - Loading

    /// Loads (or reloads) the meeting headers from disk: purges expired trash,
    /// splits live vs. trashed, and kicks off the word-count backfill + storage
    /// measurement.
    func refresh() async {
        let all = await store.listMetas()

        // Permanently drop trash past its retention window before splitting.
        let cutoff = Date().addingTimeInterval(-Self.trashRetention)
        var survivors: [MeetingMeta] = []
        survivors.reserveCapacity(all.count)
        for meta in all {
            if let trashedAt = meta.trashedAt, trashedAt < cutoff {
                do { try await store.delete(meta.id) }
                catch {
                    ErrorTrace.record(
                        "Purging expired trash failed",
                        error: error,
                        category: "MeetingLibrary",
                        metadata: ["meetingID": meta.id.uuidString]
                    )
                }
            } else {
                survivors.append(meta)
            }
        }

        metas = survivors.filter { !$0.isTrashed }
        trashedMetas = survivors
            .filter(\.isTrashed)
            .sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }

        backfillWordCountsIfNeeded()
        measureStorage()
    }

    /// Marks the start of a new recording: the previous session's live state is
    /// about to be wiped, and the "Live" row becomes the selection.
    func beginLiveSession() {
        activeMeetingID = nil
        selection = .live
    }

    /// Persists a freshly stopped recording (SPEC-03 criterion 1: saved BEFORE
    /// summary generation, so an LLM crash never loses the transcript). The word
    /// count is denormalized here — the library owns the segments at save time,
    /// so the list never has to load a transcript to show it. Returns the new
    /// id, or `nil` if the write failed (logged; the session is not interrupted).
    func persist(segments: [TranscriptSegment], startedAt: Date, endedAt: Date) async -> UUID? {
        let meta = MeetingMeta(
            id: UUID(),
            title: MeetingMeta.autoTitle(startedAt: startedAt),
            startedAt: startedAt,
            endedAt: endedAt,
            segmentCount: segments.count,
            hasSummary: false,
            wordCount: MeetingMeta.wordCount(of: segments)
        )
        do {
            try await store.save(MeetingRecord(meta: meta, segments: segments, summary: nil))
            await refresh()
            activeMeetingID = meta.id
            section = .all
            selection = .meeting(meta.id)
            return meta.id
        } catch {
            ErrorTrace.record("Saving meeting failed", error: error, category: "MeetingLibrary")
            return nil
        }
    }

    /// Attaches a finished summary (and its AI one-line caption) to an
    /// already-saved meeting (SPEC-03 criterion 2), recording which summary
    /// model wrote it (SP-007, ADR-022). A failure leaves the meeting saved
    /// without a summary.
    func attachSummary(
        _ summary: MeetingSummary,
        description: String? = nil,
        modelName: String? = nil,
        to id: UUID
    ) async {
        do {
            try await store.attachSummary(summary, description: description, modelName: modelName, to: id)
            await refresh()
        } catch {
            ErrorTrace.record(
                "Attaching summary failed",
                error: error,
                category: "MeetingLibrary",
                metadata: ["meetingID": id.uuidString]
            )
        }
    }

    /// Loads a full meeting for the detail view. Returns `nil` (logged) if the
    /// folder is missing or corrupt, so the UI can show an "unavailable" state
    /// instead of crashing.
    func loadRecord(_ id: UUID) async -> MeetingRecord? {
        do {
            return try await store.loadRecord(id)
        } catch {
            ErrorTrace.record(
                "Loading meeting failed",
                error: error,
                category: "MeetingLibrary",
                metadata: ["meetingID": id.uuidString]
            )
            return nil
        }
    }

    // MARK: - Finalization passthroughs (SP-005 S1)

    /// Moves the session's staged retention files into the meeting folder,
    /// arming the pending-finalization marker (ADR-016). Returns the adopted
    /// URLs, or `nil` on failure (logged; the pass is skipped and the live
    /// transcript stands).
    func adoptRetainedAudio(_ staged: [AudioChannel: URL], for id: UUID) async -> [AudioChannel: URL]? {
        do {
            return try await store.adoptRetainedAudio(staged, for: id)
        } catch {
            ErrorTrace.record(
                "Adopting retained audio failed",
                error: error,
                category: "MeetingLibrary",
                metadata: ["meetingID": id.uuidString]
            )
            return nil
        }
    }

    /// Atomically replaces a meeting's transcript with the final segment set
    /// (ADR-016), recording its provenance in the same meta re-derivation step
    /// (SP-007, ADR-022), and refreshes the headers so the re-derived counts
    /// reach the list. Returns whether the replace landed — a failure leaves
    /// the live transcript byte-identical (logged).
    func replaceTranscript(
        _ segments: [TranscriptSegment],
        provenance: TranscriptProvenance,
        for id: UUID
    ) async -> Bool {
        do {
            try await store.replaceTranscript(segments, provenance: provenance, for: id)
            await refresh()
            return true
        } catch {
            ErrorTrace.record(
                "Replacing transcript failed — live transcript stands",
                error: error,
                category: "MeetingLibrary",
                metadata: ["meetingID": id.uuidString]
            )
            return false
        }
    }

    /// Records that the meeting's persisted transcript is the live floor —
    /// one atomic meta write, nothing else touched (SP-007, ADR-022/ADR-024).
    /// Best-effort: a failure is logged and the meeting stays diagnosable as
    /// "unknown" provenance rather than blocking the stop path.
    func recordLiveFloorProvenance(for id: UUID, provenance: TranscriptProvenance) async {
        do {
            try await store.recordLiveFloorProvenance(for: id, provenance: provenance)
            await refresh()
        } catch {
            ErrorTrace.record(
                "Recording live-floor provenance failed",
                error: error,
                category: "MeetingLibrary",
                metadata: ["meetingID": id.uuidString]
            )
        }
    }

    /// Deletes exactly the meeting's retained-audio files (named targets,
    /// never a sweep). Failures are non-fatal and logged by the store.
    func deleteRetainedAudio(for id: UUID) async {
        await store.deleteRetainedAudio(for: id)
    }

    /// The retained-audio files currently in the meeting's folder (SP-005 S4:
    /// a launch-resumed pass re-reads them from disk — the audio is the
    /// checkpoint, ADR-016).
    func retainedAudioFiles(for id: UUID) async -> [AudioChannel: URL] {
        await store.retainedAudioFiles(for: id)
    }

    #if DEBUG
    /// SP-007 DEBUG keep flag (user story 12): renames the meeting's retained
    /// audio to its kept-fixture names inside the same folder, so a successful
    /// pass leaves a replayable real-meeting fixture behind instead of
    /// deleting the audio. Returns whether anything was preserved.
    @discardableResult
    func preserveRetainedAudioAsDebugFixture(for id: UUID) async -> Bool {
        await store.preserveRetainedAudioAsDebugFixture(for: id)
    }
    #endif

    /// Meetings pending finalization, newest first (retained audio with no
    /// recorded transcript provenance — ADR-016 amended by ADR-024) — feeds
    /// the launch resume and the backfill's eligibility check. Terminal
    /// drafts and finalPass orphans are NOT pending.
    func pendingFinalizationMeetingIDs() async -> [UUID] {
        await store.pendingFinalizationMeetingIDs()
    }

    /// Whether the meeting still holds kept audio — the exact lifetime of
    /// the draft state's Retry affordance (SP-007/ADR-024).
    func hasRetainedAudio(for id: UUID) async -> Bool {
        await store.hasRetainedAudio(for: id)
    }

    /// Deletes the leftover audio of meetings whose provenance already says
    /// `finalPass` (ADR-024's orphan class — a success whose cleanup
    /// crashed). Part of the launch scan, before the resume enqueue.
    func sweepFinalPassAudioOrphans() async {
        await store.sweepFinalPassAudioOrphans()
    }

    /// Deletes orphaned retention staging from a previous run (disposable by
    /// design — never adopted, so no meeting references it).
    func sweepRetentionStaging() async {
        await store.sweepRetentionStaging()
    }

    // MARK: - Mutations

    /// Renames a meeting (user-editable title). Trims whitespace and ignores an
    /// empty result — a meeting always keeps a title.
    func rename(_ id: UUID, to newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var meta = meta(for: id), meta.title != trimmed else { return }
        meta.title = trimmed
        await update(meta)
    }

    /// Moves a meeting to Trash (soft-delete). It keeps all its files and is
    /// permanently removed once it has sat in Trash past `trashRetention`.
    func trash(_ id: UUID) async {
        guard var meta = meta(for: id), !meta.isTrashed else { return }
        meta.trashedAt = Date()
        if activeMeetingID == id { activeMeetingID = nil }
        if selection == .meeting(id) { selection = nil }
        await update(meta)
    }

    /// Restores a trashed meeting back into "All Meetings".
    func restore(_ id: UUID) async {
        guard var meta = trashedMetas.first(where: { $0.id == id }) else { return }
        meta.trashedAt = nil
        if selection == .meeting(id) { selection = nil }
        await update(meta)
    }

    /// Permanently deletes a meeting's folder and refreshes, clearing the
    /// selection if it pointed at the deleted meeting. Used from Trash (and by
    /// the retention purge).
    func deletePermanently(_ id: UUID) async {
        do {
            try await store.delete(id)
            if activeMeetingID == id { activeMeetingID = nil }
            if selection == .meeting(id) { selection = nil }
            await refresh()
        } catch {
            ErrorTrace.record(
                "Deleting meeting failed",
                error: error,
                category: "MeetingLibrary",
                metadata: ["meetingID": id.uuidString]
            )
        }
    }

    /// Empties the Trash: permanently deletes every trashed meeting.
    func emptyTrash() async {
        for meta in trashedMetas {
            do { try await store.delete(meta.id) }
            catch {
                ErrorTrace.record(
                    "Emptying trash failed",
                    error: error,
                    category: "MeetingLibrary",
                    metadata: ["meetingID": meta.id.uuidString]
                )
            }
        }
        if case .meeting(let id)? = selection, trashedMetas.contains(where: { $0.id == id }) {
            selection = nil
        }
        await refresh()
    }

    // MARK: - Helpers

    /// The current meta for an id from whichever list holds it.
    func meta(for id: UUID) -> MeetingMeta? {
        metas.first { $0.id == id } ?? trashedMetas.first { $0.id == id }
    }

    private func update(_ meta: MeetingMeta) async {
        do {
            try await store.updateMeta(meta)
            await refresh()
        } catch {
            ErrorTrace.record(
                "Updating meeting failed",
                error: error,
                category: "MeetingLibrary",
                metadata: ["meetingID": meta.id.uuidString]
            )
        }
    }

    /// Fills in `wordCount` for meetings saved before it was denormalized (a
    /// one-time, self-healing migration). New meetings already carry it, so this
    /// is usually a no-op. Runs in the background and patches rows in place as it
    /// goes; it never blocks a refresh.
    private func backfillWordCountsIfNeeded() {
        guard !isBackfilling else { return }
        let missing = metas.filter { $0.wordCount == nil }.map(\.id)
        guard !missing.isEmpty else { return }
        isBackfilling = true
        Task {
            defer { isBackfilling = false }
            for id in missing {
                guard let record = await loadRecord(id) else { continue }
                var meta = record.meta
                meta.wordCount = MeetingMeta.wordCount(of: record.segments)
                try? await store.updateMeta(meta)
                if let index = metas.firstIndex(where: { $0.id == id }) {
                    metas[index].wordCount = meta.wordCount
                }
            }
        }
    }

    /// Measures the meeting data's on-disk footprint off the main actor and
    /// publishes it for the sidebar footer. Only the meetings tree counts —
    /// the multi-GB AI models under Models/ are infrastructure, not user data.
    private func measureStorage() {
        Task.detached(priority: .utility) { [root = store.rootDirectory] in
            let bytes = MeetingLibrary.directorySize(at: root)
            await MainActor.run { [weak self] in self?.storageBytes = bytes }
        }
    }

    private nonisolated static func directorySize(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
