//
//  TrashView.swift
//  Workspace
//
//  Meetings set aside. A trashed meeting keeps every file, leaves the main
//  list, and is deleted for good when Trash is emptied or after the retention
//  window. From here a deletion is permanent, so the confirmation is the whole
//  safety net.
//

import DesignSystem
import Meetings
import SwiftUI

struct TrashView: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(WorkspaceModel.self) private var workspace

    @State private var hoveredID: UUID?
    @State private var confirmDelete: MeetingMeta?
    @State private var confirmEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if library.trashedMetas.isEmpty {
                EmptyState(
                    symbol: "trash",
                    title: "Trash is empty",
                    message:
                        "Meetings you move to Trash stay here for \(Int(MeetingLibrary.trashRetention / 86_400)) days before they are deleted."
                )
            } else {
                list
            }
        }
        .confirmationDialog(
            "Delete “\(confirmDelete?.title ?? "")” permanently?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let meta = confirmDelete {
                    Task { await library.deletePermanently(meta.id) }
                }
                confirmDelete = nil
            }
        } message: {
            Text("Its transcript, notes and any saved recording are removed from this Mac. This cannot be undone.")
        }
        .confirmationDialog("Empty Trash?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) {
                Task { await library.emptyTrash() }
            }
        } message: {
            Text(
                "All \(library.trashedMetas.count) meetings in Trash are removed from this Mac. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Trash")
                .font(EchoFont.documentTitle)
                .foregroundStyle(EchoColor.textPrimary)
            Spacer()
            Button("Empty Trash…") { confirmEmpty = true }
                .buttonStyle(.echoDestructive)
                .disabled(library.trashedMetas.isEmpty)
        }
        .padding(.horizontal, EchoSpacing.xl)
        .padding(.vertical, EchoSpacing.l)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: EchoSpacing.xxs) {
                ForEach(library.trashedMetas) { meta in
                    row(meta)
                }
            }
            .padding(EchoSpacing.l)
            .frame(maxWidth: EchoLayout.readingWidth, alignment: .leading)
        }
    }

    private func row(_ meta: MeetingMeta) -> some View {
        let isSelected = workspace.selectedTrashedID == meta.id
        return HStack(spacing: EchoSpacing.m) {
            VStack(alignment: .leading, spacing: EchoSpacing.xxs) {
                Text(meta.title)
                    .font(EchoFont.row)
                    .foregroundStyle(EchoColor.textPrimary)
                    .lineLimit(1)
                Text(deletionText(meta))
                    .font(EchoFont.rowDetail)
                    .foregroundStyle(EchoColor.textSecondary)
            }
            Spacer()
            if isSelected || hoveredID == meta.id {
                Button("Restore") { Task { await library.restore(meta.id) } }
                    .buttonStyle(.echoSecondary)
                Button("Delete…") { confirmDelete = meta }
                    .buttonStyle(.echoDestructive)
            }
        }
        .padding(.horizontal, EchoSpacing.m)
        .padding(.vertical, EchoSpacing.s)
        .background(SelectableRowChrome(isSelected: isSelected, isHovered: hoveredID == meta.id))
        .contentShape(.rect(cornerRadius: EchoRadius.row))
        .onTapGesture { workspace.selectedTrashedID = meta.id }
        .onHover { hovering in hoveredID = hovering ? meta.id : (hoveredID == meta.id ? nil : hoveredID) }
        .contextMenu {
            Button("Restore") { Task { await library.restore(meta.id) } }
            Button("Delete Permanently…", role: .destructive) { confirmDelete = meta }
        }
    }

    /// "Deleted 3 days ago · 27 days left".
    private func deletionText(_ meta: MeetingMeta) -> String {
        guard let trashedAt = meta.trashedAt else { return "" }
        let deletedAgo = trashedAt.formatted(.relative(presentation: .named))
        let remaining = trashedAt.addingTimeInterval(MeetingLibrary.trashRetention).timeIntervalSinceNow
        let daysLeft = max(0, Int((remaining / 86_400).rounded(.up)))
        return "Deleted \(deletedAgo) · \(daysLeft) days left"
    }
}
