//
//  RenameMeeting.swift
//  Workspace
//
//  Rename…, asked the same way wherever it is offered: the sidebar row's menu
//  and the document's "…". The field starts on the meeting's current title,
//  and the library decides what an acceptable title is (it trims, and ignores
//  an empty one).
//

import Meetings
import SwiftUI

extension View {
    /// Asks for a new title while `target` names a meeting, and clears it
    /// when the alert closes either way.
    func renameMeetingAlert(_ target: Binding<MeetingMeta?>) -> some View {
        modifier(RenameMeetingAlert(target: target))
    }
}

private struct RenameMeetingAlert: ViewModifier {
    @Environment(MeetingLibrary.self) private var library

    @Binding var target: MeetingMeta?
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: target?.id) { _, _ in
                if let target { text = target.title }
            }
            .alert("Rename Meeting", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
                TextField("Title", text: $text)
                Button("Rename") {
                    if let target {
                        let title = text
                        Task { await library.rename(target.id, to: title) }
                    }
                    target = nil
                }
                Button("Cancel", role: .cancel) { target = nil }
            }
    }
}
