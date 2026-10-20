//
//  TrashView.swift
//  Workspace
//
//  Meetings set aside, as the Trash artboard draws them in the document's
//  place. A trashed meeting keeps every file, leaves the main list, and is
//  deleted for good when Trash is emptied or after the thirty days, which
//  each row counts down, the last few in red. Restore and Delete show on the
//  selected or hovered row only. A double click opens a row's document to
//  look at without taking it out, and so does Return; ↑↓ move, and Delete
//  asks before removing a meeting for good — the confirmation is the whole
//  safety net, since from here a deletion cannot be undone.
//
//  The buttons drop the artboard's "…": what they do is plain from their
//  words, and the question that follows is the safety, not the label
//  (product owner, 2026-10-20).
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
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if library.trashedMetas.isEmpty {
                // The one empty face with nothing to offer: there is truly
                // nothing to do.
                EmptyState(
                    glyph: .trash, title: "Trash is empty",
                    message:
                        "Meetings you delete land here and are removed for good after \(Self.retentionDays) days."
                )
            } else {
                Text("Meetings you delete land here and are removed for good after \(Self.retentionDays) days.")
                    .font(EchoFont.control)
                    .foregroundStyle(EchoColor.textQuaternary)
                    .padding(.horizontal, EchoLayout.listHeaderLeadingInset)
                    .padding(.bottom, EchoLayout.listNoteBottom)
                list
                footer
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
        .onAppear { listFocused = true }
    }

    private static var retentionDays: Int { Int(MeetingLibrary.trashRetention / 86_400) }

    // MARK: Header

    private var header: some View {
        HStack(spacing: EchoLayout.listHeaderGap) {
            Text("Trash")
                .font(EchoFont.listTitle)
                .tracking(EchoFont.listTitleTracking)
                .foregroundStyle(EchoColor.textPrimary)
            if !library.trashedMetas.isEmpty {
                Text("\(library.trashedMetas.count)")
                    .font(EchoFont.mono(11.5))
                    .foregroundStyle(EchoColor.textSecondary)
                    .padding(.horizontal, EchoControl.listCountInset.width)
                    .padding(.vertical, EchoControl.listCountInset.height)
                    .background(EchoColor.surfaceRaised, in: .capsule)
                Spacer(minLength: 0)
                Button("Empty Trash") { confirmEmpty = true }
                    .buttonStyle(.echoControlDestructive)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, EchoLayout.listHeaderLeadingInset)
        .padding(.trailing, EchoLayout.listHeaderTrailingInset)
        .frame(height: EchoLayout.listHeaderHeight)
    }

    // MARK: The list

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: EchoLayout.listRowSpacing) {
                    ForEach(library.trashedMetas) { meta in
                        row(meta)
                            .id(meta.id)
                    }
                }
                .padding(.horizontal, EchoLayout.listInset)
            }
            .scrollIndicators(.never)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.upArrow) { move(.up, proxy) }
            .onKeyPress(.downArrow) { move(.down, proxy) }
            .onKeyPress(.home) { move(.first, proxy) }
            .onKeyPress(.end) { move(.last, proxy) }
            .onKeyPress(.return) {
                guard let id = workspace.selectedTrashedID else { return .ignored }
                workspace.openTrashed(id)
                return .handled
            }
            .onDeleteCommand {
                if let id = workspace.selectedTrashedID {
                    confirmDelete = library.trashedMetas.first { $0.id == id }
                }
            }
        }
    }

    private func move(_ move: MeetingListSelection.Move, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard workspace.moveTrashSelection(move, in: library.trashedMetas) else { return .ignored }
        if let id = workspace.selectedTrashedID {
            proxy.scrollTo(id, anchor: nil)
        }
        return .handled
    }

    private func row(_ meta: MeetingMeta) -> some View {
        let isSelected = workspace.selectedTrashedID == meta.id
        let isHovered = hoveredID == meta.id
        let isActive = isSelected || isHovered
        let days = meta.trashedAt.map { TrashRow.daysLeft(trashedAt: $0) }
        return HStack(spacing: EchoLayout.listRowGap) {
            DocumentGlyph()
                .stroke(
                    isActive ? EchoColor.textTertiary : EchoColor.textQuaternary,
                    style: StrokeStyle(
                        lineWidth: DocumentGlyph.lineWidth(at: EchoControl.listRowGlyphSize), lineJoin: .round)
                )
                .frame(width: EchoControl.listRowGlyphSize, height: EchoControl.listRowGlyphSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(meta.title)
                    .font(isSelected ? EchoFont.rowTitleSelected : EchoFont.rowTitle)
                    .foregroundStyle(
                        isSelected ? EchoColor.textPrimary : (isHovered ? EchoColor.textValue : EchoColor.textSecondary)
                    )
                caption(TrashRow.caption(meta))
                    .font(EchoFont.rowCaption)
                    .foregroundStyle(isActive ? EchoColor.textTertiary : EchoColor.textQuaternary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let bytes = library.storage?.trashedFolderBytes[meta.id] {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(EchoFont.mono(11.5))
                    .foregroundStyle(isActive ? EchoColor.textQuaternary : EchoColor.textFaint)
                    .fixedSize()
            }

            Text(days.map(TrashRow.daysLeftText) ?? "")
                .font(EchoFont.rowCaption)
                .foregroundStyle(
                    days.map(TrashRow.isExpiring) == true
                        ? EchoColor.destructiveText : (isActive ? EchoColor.textQuaternary : EchoColor.textFaint)
                )
                .frame(width: EchoLayout.listDaysWidth, alignment: .trailing)

            // The column is kept on every row, so sizes and days line up
            // whether or not a row shows its buttons.
            HStack(spacing: EchoControl.listRowActionGap) {
                if isActive {
                    // On the selected row the control's raised fill is the
                    // row's own; it takes the window's background instead.
                    Button("Restore") { Task { await library.restore(meta.id) } }
                        .buttonStyle(isSelected ? .echoControlOnSelection : .echoControl)
                    Button("Delete") { confirmDelete = meta }
                        .buttonStyle(.echoControlDestructive)
                }
            }
            .frame(width: EchoLayout.listActionsWidth, alignment: .trailing)
        }
        .padding(.horizontal, EchoLayout.listRowInset)
        .frame(height: EchoLayout.listRowHeight)
        .background(
            isSelected ? EchoColor.surfaceRaised : (isHovered ? EchoColor.surface : .clear),
            in: .rect(cornerRadius: EchoRadius.listRow)
        )
        .contentShape(.rect(cornerRadius: EchoRadius.listRow))
        // The first click selects at once; the second of a double click
        // opens, as Finder's do.
        .onTapGesture {
            workspace.selectedTrashedID = meta.id
            listFocused = true
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { workspace.openTrashed(meta.id) })
        .onHover { hovering in hoveredID = hovering ? meta.id : (hoveredID == meta.id ? nil : hoveredID) }
        .contextMenu {
            Button("Open") { workspace.openTrashed(meta.id) }
            Button("Restore") { Task { await library.restore(meta.id) } }
            Divider()
            Button("Delete Permanently…", role: .destructive) { confirmDelete = meta }
        }
    }

    /// "Aug 24, 2026 · 31 min · 2,140 words", the numbers in the
    /// monospaced face.
    private func caption(_ caption: TrashRow.Caption) -> Text {
        let duration = Text(caption.duration).font(EchoFont.mono(11.5))
        switch caption.detail {
        case .words(let words):
            return Text(
                "\(caption.day) · \(duration) · \(Text("\(words.formatted()) words").font(EchoFont.mono(11.5)))")
        case .noSummary:
            return Text("\(caption.day) · \(duration) · no summary")
        case nil:
            return Text("\(caption.day) · \(duration)")
        }
    }

    // MARK: Footer

    /// What the keyboard does, and what Trash holds on disk.
    private var footer: some View {
        VStack(spacing: 0) {
            EchoColor.divider
                .frame(height: EchoLayout.hairline)
            HStack(spacing: EchoLayout.listFooterGap) {
                Text("Selected row answers the keyboard:")
                    .font(EchoFont.rowCaption)
                    .foregroundStyle(EchoColor.textFaint)
                KeyHint(key: "↑↓", label: "Move")
                KeyHint(key: "↵", label: "Open")
                KeyHint(key: "⌫", label: "Ask before deleting for good")
                Spacer(minLength: 0)
                if let bytes = library.storage?.trashBytes {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(EchoFont.mono(11))
                        .foregroundStyle(EchoColor.textFaint)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, EchoLayout.listHeaderLeadingInset)
            .frame(height: EchoLayout.listFooterHeight)
        }
    }
}

/// A key and what it does, as the footer draws its hints.
private struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: EchoLayout.keyHintGap) {
            Text(key)
                .font(EchoFont.mono(10.5))
                .padding(.horizontal, EchoControl.keycapInset.width)
                .padding(.vertical, EchoControl.keycapInset.height)
                .overlay {
                    RoundedRectangle(cornerRadius: EchoRadius.keycap)
                        .strokeBorder(EchoColor.inertBorder, lineWidth: EchoLayout.hairline)
                }
            Text(label)
                .font(EchoFont.micro)
        }
        .foregroundStyle(EchoColor.textQuaternary)
        .fixedSize()
    }
}

/// A page with its corner folded, on the artboard's 16 × 16 grid: the
/// glyph at the head of a Trash row.
private nonisolated struct DocumentGlyph: Shape {

    /// The stroke the artboard draws, scaled with the glyph.
    static func lineWidth(at size: CGFloat) -> CGFloat { 1.35 * size / 16 }

    func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect)
        var path = Path()
        func corner(_ x: CGFloat, _ y: CGFloat, toward nextX: CGFloat, _ nextY: CGFloat) {
            path.addArc(
                tangent1End: grid.point(x, y), tangent2End: grid.point(nextX, nextY), radius: grid.length(0.8))
        }
        path.move(to: grid.point(3.4, 2.2))
        path.addLine(to: grid.point(9, 2.2))
        path.addLine(to: grid.point(12.6, 5.8))
        corner(12.6, 14.6, toward: 2.6, 14.6)
        corner(2.6, 14.6, toward: 2.6, 2.2)
        corner(2.6, 2.2, toward: 12.6, 2.2)
        path.closeSubpath()
        // The fold.
        path.move(to: grid.point(9, 2.2))
        path.addLine(to: grid.point(9, 6))
        path.addLine(to: grid.point(12.6, 6))
        return path
    }
}
