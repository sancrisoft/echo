//
//  Breadcrumb.swift
//  Workspace
//
//  The bar above a document: where it sits — the library, then the document
//  itself — and, at the bar's other end, what can be done with it. A meeting
//  carries Copy, Export and the "…"; the session being recorded carries
//  nothing, because there is nothing on disk yet to act on.
//

import DesignSystem
import SwiftUI

struct Breadcrumb<Actions: View>: View {
    let trail: String
    let current: String
    let actions: Actions

    init(trail: String, current: String, @ViewBuilder actions: () -> Actions) {
        self.trail = trail
        self.current = current
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(trail)
                .foregroundStyle(EchoColor.textQuaternary)
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
}

extension Breadcrumb where Actions == EmptyView {
    init(trail: String, current: String) {
        self.init(trail: trail, current: current) { EmptyView() }
    }
}
