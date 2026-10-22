//
//  Breadcrumb.swift
//  Workspace
//
//  The bar above a document: where it sits — the library, then the document
//  itself — and, at the bar's other end, what can be done with it. A meeting
//  carries Copy, Export and the "…"; the session being recorded carries
//  nothing, because there is nothing on disk yet to act on. Where the trail
//  leads somewhere — Trash, from a trashed meeting's document — it is a link
//  back there (product owner, 2026-10-20).
//

import DesignSystem
import SwiftUI

struct Breadcrumb<Actions: View>: View {
    let trail: String
    let current: String
    /// Where clicking the trail goes; `nil` when it goes nowhere.
    let back: (() -> Void)?
    let actions: Actions

    @State private var isTrailHovered = false

    init(trail: String, current: String, back: (() -> Void)? = nil, @ViewBuilder actions: () -> Actions) {
        self.trail = trail
        self.current = current
        self.back = back
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 0) {
            trailView
            Text("/")
                .foregroundStyle(EchoColor.breadcrumbSlash)
                .padding(.horizontal, EchoLayout.breadcrumbSlashGap)
                .accessibilityHidden(true)
            // A long title gives way before the actions do.
            Text(current)
                .foregroundStyle(EchoColor.textSecondary)
                .truncationMode(.tail)
            Spacer(minLength: EchoSpacing.l)
            actions
                .fixedSize()
        }
        .font(EchoFont.control)
        .lineLimit(1)
        .padding(.horizontal, EchoLayout.breadcrumbInset)
        .frame(height: EchoLayout.breadcrumbHeight)
    }

    /// A link brightens to the current item's ink under the pointer, so it
    /// reads as one before it is clicked.
    @ViewBuilder
    private var trailView: some View {
        if let back {
            Button(action: back) {
                Text(trail)
                    .foregroundStyle(isTrailHovered ? EchoColor.textSecondary : EchoColor.textQuaternary)
            }
            .buttonStyle(.plain)
            .onHover { isTrailHovered = $0 }
            .accessibilityHint("Goes back to \(trail)")
        } else {
            Text(trail)
                .foregroundStyle(EchoColor.textQuaternary)
        }
    }
}

extension Breadcrumb where Actions == EmptyView {
    init(trail: String, current: String) {
        self.init(trail: trail, current: current, back: nil) { EmptyView() }
    }
}
