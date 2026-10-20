//
//  SavedRecordingActions.swift
//  Workspace
//
//  What a meeting that keeps its recording offers: Re-transcribe and Delete
//  Recording, in the document's "…" and the sidebar row's menu (product
//  owner, 2026-10-20). Each asks first, in v1's words: re-transcribing
//  replaces the transcript and the summary, and deleting the audio cannot be
//  undone. Which meetings keep a recording, and how much it is, comes from
//  the library's one storage measurement, so a menu can be built without
//  waiting on the disk.
//

import Meetings
import Recording
import SwiftUI

extension View {
    /// Asks before re-transcribing `retranscribe` or deleting the recording of
    /// `deleteRecording`, whichever is set, and clears it either way.
    func savedRecordingDialogs(
        retranscribe: Binding<MeetingMeta?>, deleteRecording: Binding<MeetingMeta?>
    ) -> some View {
        modifier(SavedRecordingDialogs(retranscribe: retranscribe, deleteRecording: deleteRecording))
    }
}

extension MeetingLibrary {
    /// Whether the meeting keeps its recording, as last measured.
    func keepsRecording(_ id: UUID) -> Bool {
        storage?.recordingBytes[id] != nil
    }
}

/// The two menu items, for a menu being built for `meta`. Nothing when the
/// meeting keeps no recording; Re-transcribe held back while a pass for it
/// is queued or running.
struct SavedRecordingMenuItems: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(RecordingSession.self) private var session

    let meta: MeetingMeta
    @Binding var retranscribe: MeetingMeta?
    @Binding var deleteRecording: MeetingMeta?

    var body: some View {
        if library.keepsRecording(meta.id) {
            Button("Re-transcribe") { retranscribe = meta }
                .disabled(session.queuedMeetingIDs.contains(meta.id) || session.phase.meetingID == meta.id)
            Button("Delete Recording") { deleteRecording = meta }
        }
    }
}

private struct SavedRecordingDialogs: ViewModifier {
    @Environment(MeetingLibrary.self) private var library
    @Environment(RecordingSession.self) private var session

    @Binding var retranscribe: MeetingMeta?
    @Binding var deleteRecording: MeetingMeta?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Re-transcribe this meeting?",
                isPresented: Binding(get: { retranscribe != nil }, set: { if !$0 { retranscribe = nil } }),
                titleVisibility: .visible
            ) {
                Button("Re-transcribe") {
                    if let id = retranscribe?.id {
                        Task { await session.retranscribe(id) }
                    }
                    retranscribe = nil
                }
                Button("Cancel", role: .cancel) { retranscribe = nil }
            } message: {
                Text(
                    "Replaces this meeting's transcript and summary by re-running transcription on the saved recording. The recording itself is kept."
                )
            }
            .confirmationDialog(
                "Delete this recording?",
                isPresented: Binding(get: { deleteRecording != nil }, set: { if !$0 { deleteRecording = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Recording", role: .destructive) {
                    if let id = deleteRecording?.id {
                        Task { await library.deletePreservedAudio(for: id) }
                    }
                    deleteRecording = nil
                }
                Button("Cancel", role: .cancel) { deleteRecording = nil }
            } message: {
                Text(deleteMessage)
            }
    }

    private var deleteMessage: String {
        let size =
            deleteRecording.flatMap { library.storage?.recordingBytes[$0.id] }
            .map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? ""
        return "The saved audio\(size) will be deleted. The transcript and summary stay. This cannot be undone."
    }
}
