//
//  Primitives.swift
//  DesignSystem
//
//  The pieces every surface repeats, implemented once: button styles, a status
//  badge, a property row, a segmented tab strip, an empty state, and the
//  chrome behind a selectable row. Each takes tokens, never literals, and
//  knows nothing about meetings.
//

import SwiftUI

// MARK: - Buttons

/// The window's button family. One primary per screen; secondary for the
/// rest; quiet for actions that should not compete with content.
public struct EchoButtonStyle: ButtonStyle {

    public enum Role: Sendable {
        case primary
        case secondary
        case quiet
        /// A quiet button whose label is a glyph: the breadcrumb bar's "…",
        /// square at the toolbar buttons' height.
        case quietIcon
        case destructive
        /// A row's own action, as the models panel and the welcome screen
        /// draw it — Pause, Resume, Retry: smaller than the title bar's
        /// button, on the raised fill with the inert edge.
        case control
        /// The row action that is the step itself, at the control's size and
        /// in the primary's inverted fill: the welcome screen's Allow and
        /// Open System Settings.
        case controlProminent
        /// The welcome screen's Start using Echo: the primary, larger.
        case prominent
    }

    private let role: Role

    public init(_ role: Role = .secondary) {
        self.role = role
    }

    public func makeBody(configuration: Configuration) -> some View {
        Drawn(configuration: configuration, role: role)
    }

    /// The drawn button, a view of its own so it can read whether it is
    /// enabled: a style cannot.
    ///
    /// The design draws one held-back button — the welcome screen's Start
    /// using Echo, greyed until the setup is done, with the reason beside it —
    /// and the title bar's New recording takes the same look. A held-back
    /// primary or prominent keeps its shape and size and trades the inverted
    /// fill for a raised grey one with an inert edge, so neither screen
    /// changes its layout while it explains why. The other roles have no
    /// drawn held-back look and keep the one they have.
    private struct Drawn: View {
        let configuration: Configuration
        let role: Role

        @Environment(\.isEnabled) private var isEnabled

        private var isHeldBack: Bool { (role == .primary || role == .prominent) && !isEnabled }

        var body: some View {
            configuration.label
                .font(font)
                .lineLimit(1)
                .frame(width: role == .quietIcon ? height : nil, height: height)
                .padding(.horizontal, inset)
                .foregroundStyle(foreground)
                .background(background(pressed: configuration.isPressed), in: .rect(cornerRadius: radius))
                .overlay {
                    if let edge {
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(edge, lineWidth: 1)
                    }
                }
                .contentShape(.rect(cornerRadius: radius))
                .opacity(configuration.isPressed ? 0.85 : 1)
        }

        /// A quiet button is a toolbar button and takes that shape; everything
        /// with a fill takes the shape of the one filled button the design
        /// draws, so buttons on a screen line up whatever their role.
        private var font: Font {
            switch role {
            case .primary, .controlProminent: return EchoFont.primaryButton
            case .prominent: return EchoFont.prominentButton
            case .secondary, .quiet, .quietIcon, .destructive, .control: return EchoFont.control
            }
        }

        private var height: CGFloat {
            switch role {
            case .quiet, .quietIcon: return EchoLayout.toolbarButtonHeight
            case .control, .controlProminent: return EchoControl.controlButtonHeight
            case .prominent: return EchoControl.prominentButtonHeight
            case .primary, .secondary, .destructive: return EchoControl.primaryButtonHeight
            }
        }

        private var inset: CGFloat {
            switch role {
            case .quiet: return EchoControl.toolbarButtonInset
            case .quietIcon: return 0
            case .control, .controlProminent: return EchoControl.controlButtonInset
            case .prominent: return EchoControl.prominentButtonInset
            case .primary, .secondary, .destructive: return EchoControl.primaryButtonInset
            }
        }

        private var radius: CGFloat {
            switch role {
            case .quiet, .quietIcon, .control, .controlProminent: return EchoRadius.row
            case .primary, .secondary, .destructive, .prominent: return EchoRadius.control
            }
        }

        private var edge: Color? {
            if isHeldBack { return EchoColor.inertBorder }
            switch role {
            case .secondary: return EchoColor.border
            case .control: return EchoColor.inertBorder
            case .primary, .quiet, .quietIcon, .destructive, .controlProminent, .prominent: return nil
            }
        }

        private var foreground: Color {
            if isHeldBack { return EchoColor.textQuaternary }
            switch role {
            // The design's one filled button is the interface inverted: the
            // text takes the window's own background, whichever appearance
            // that is.
            case .primary, .controlProminent, .prominent: return EchoColor.windowBackground
            case .secondary: return EchoColor.textPrimary
            case .quiet, .quietIcon: return EchoColor.textSecondary
            case .destructive: return EchoColor.danger
            case .control: return EchoColor.textValue
            }
        }

        private func background(pressed: Bool) -> Color {
            if isHeldBack { return EchoColor.surfaceRaised }
            switch role {
            // Not the accent. The accent marks selection and links; a button
            // that wore it would be the loudest thing on a grey screen.
            case .primary, .controlProminent, .prominent: return EchoColor.textPrimary.opacity(pressed ? 0.85 : 1)
            case .secondary, .control: return EchoColor.surfaceRaised.opacity(pressed ? 0.7 : 1)
            case .quiet, .quietIcon: return pressed ? EchoColor.hover : .clear
            case .destructive: return EchoColor.danger.opacity(pressed ? 0.16 : 0.1)
            }
        }
    }
}

extension ButtonStyle where Self == EchoButtonStyle {
    public static var echoPrimary: EchoButtonStyle { EchoButtonStyle(.primary) }
    public static var echoSecondary: EchoButtonStyle { EchoButtonStyle(.secondary) }
    public static var echoQuiet: EchoButtonStyle { EchoButtonStyle(.quiet) }
    public static var echoQuietIcon: EchoButtonStyle { EchoButtonStyle(.quietIcon) }
    public static var echoDestructive: EchoButtonStyle { EchoButtonStyle(.destructive) }
    public static var echoControl: EchoButtonStyle { EchoButtonStyle(.control) }
    public static var echoControlProminent: EchoButtonStyle { EchoButtonStyle(.controlProminent) }
    public static var echoProminent: EchoButtonStyle { EchoButtonStyle(.prominent) }
}

// MARK: - Status badge

/// A small capsule that names a state: "Summarized", "Draft", "Failed".
public struct StatusBadge: View {

    public enum Tone: Sendable, Equatable {
        case neutral
        case accent
        case success
        case warning
        case danger
        case recording
    }

    private let text: String
    private let tone: Tone
    private let showsCheck: Bool

    /// - Parameter showsCheck: a check before the word, in the pill's own
    ///   colour — the models panel's "Ready".
    public init(_ text: String, tone: Tone = .neutral, showsCheck: Bool = false) {
        self.text = text
        self.tone = tone
        self.showsCheck = showsCheck
    }

    public var body: some View {
        HStack(spacing: EchoControl.pillGap) {
            if tone == .recording {
                Circle()
                    .fill(EchoColor.recording)
                    .frame(width: EchoControl.pillDotSize, height: EchoControl.pillDotSize)
                    .accessibilityHidden(true)
            }
            if showsCheck {
                ReadyCheckGlyph()
                    .frame(width: EchoControl.readyCheckSize, height: EchoControl.readyCheckSize)
                    .accessibilityHidden(true)
            }
            Text(text)
        }
        .font(EchoFont.statusPill)
        .foregroundStyle(color)
        .padding(.horizontal, EchoControl.pillInset.width)
        .padding(.vertical, EchoControl.pillInset.height)
        .background(fill, in: .rect(cornerRadius: EchoRadius.pill))
        .lineLimit(1)
        .fixedSize()
    }

    /// The design draws two of these: the accent pill on the accent's own
    /// wash, and the live one — the red lifted for the word, a red dot before
    /// it. The other tones are states it has not drawn, and they borrow the
    /// wash's weight rather than inventing one.
    private var fill: Color {
        switch tone {
        case .accent: EchoColor.accentWash
        case .recording: EchoColor.recordingPillWash
        case .neutral, .success, .warning, .danger: color.opacity(0.15)
        }
    }

    private var color: Color {
        switch tone {
        case .neutral: return EchoColor.textSecondary
        case .accent: return EchoColor.accent
        case .success: return EchoColor.success
        case .warning: return EchoColor.warning
        case .danger: return EchoColor.danger
        case .recording: return EchoColor.recordingTimer
        }
    }
}

// MARK: - Property row

/// One fact under a document's title: an icon and its word in a fixed column,
/// then the value. The column is a fixed width so every row's value starts at
/// the same place, whatever the label says.
public struct PropertyRow<Value: View>: View {

    private let symbol: String
    private let label: String
    private let value: Value

    public init(symbol: String, label: String, @ViewBuilder value: () -> Value) {
        self.symbol = symbol
        self.label = label
        self.value = value()
    }

    public var body: some View {
        HStack(spacing: EchoControl.propertyGap) {
            HStack(spacing: EchoSpacing.s) {
                Image(systemName: symbol)
                    .font(.system(size: EchoControl.propertyIconSize))
                    .frame(width: EchoControl.propertyIconSize, height: EchoControl.propertyIconSize)
                Text(label)
                    .font(EchoFont.propertyLabel)
                    .lineLimit(1)
            }
            .foregroundStyle(EchoColor.textTertiary)
            .frame(width: EchoLayout.propertyLabelWidth, alignment: .leading)

            value
                .font(EchoFont.propertyValue)
                .foregroundStyle(EchoColor.textValue)

            Spacer(minLength: 0)
        }
        .frame(height: EchoLayout.propertyRowHeight)
    }
}

extension PropertyRow where Value == Text {
    /// The common case: a value that is one line of text.
    public init(symbol: String, label: String, _ value: String) {
        self.init(symbol: symbol, label: label) { Text(value) }
    }
}

// MARK: - Segmented tab strip

/// The document's tabs: segments inside a well, the selected one raised.
///
/// Selection is passed in and passed back; the strip owns nothing. A screen
/// that switches tabs keeps that state where the rest of its navigation lives.
public struct TabStrip<Tab: Hashable>: View {

    private let tabs: [Tab]
    @Binding private var selection: Tab
    private let title: (Tab) -> String

    public init(_ tabs: [Tab], selection: Binding<Tab>, title: @escaping (Tab) -> String) {
        self.tabs = tabs
        self._selection = selection
        self.title = title
    }

    public var body: some View {
        HStack(spacing: EchoControl.tabGap) {
            ForEach(tabs, id: \.self) { tab in
                let isSelected = tab == selection
                Button {
                    selection = tab
                } label: {
                    Text(title(tab))
                        .font(isSelected ? EchoFont.controlSelected : EchoFont.control)
                        .foregroundStyle(isSelected ? EchoColor.textPrimary : EchoColor.textSecondary)
                        .lineLimit(1)
                        .frame(height: EchoLayout.toolbarButtonHeight)
                        .padding(.horizontal, EchoControl.tabInset)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: EchoRadius.row, style: .continuous)
                                    .fill(EchoColor.surfaceSelected)
                                    .shadow(
                                        color: EchoColor.tabSelectionShadow,
                                        radius: EchoControl.tabSelectionShadowRadius,
                                        y: EchoControl.tabSelectionShadowOffset)
                            }
                        }
                        .contentShape(.rect(cornerRadius: EchoRadius.row))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(EchoControl.tabStripInset)
        .background(EchoColor.surface, in: .rect(cornerRadius: EchoRadius.well))
        .fixedSize()
    }
}

// MARK: - Empty state

/// The screen when there is nothing to show: an icon, a title, a line of copy,
/// and optionally one action.
public struct EmptyState<Action: View>: View {
    private let symbol: String
    private let title: String
    private let message: String
    private let action: Action

    public init(symbol: String, title: String, message: String, @ViewBuilder action: () -> Action) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action()
    }

    public var body: some View {
        VStack(spacing: EchoSpacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(EchoColor.textTertiary)
            Text(title)
                .font(EchoFont.sectionTitle)
                .foregroundStyle(EchoColor.textPrimary)
            Text(message)
                .font(EchoFont.body)
                .foregroundStyle(EchoColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            action
                .padding(.top, EchoSpacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(EchoSpacing.xxl)
    }
}

extension EmptyState where Action == EmptyView {
    public init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Selectable row chrome

/// The background behind a list row: the selection fill when selected, a hover
/// wash when hovered, nothing otherwise. Installed by the row, so a list never
/// paints a second highlight on top.
public struct SelectableRowChrome: View {
    private let isSelected: Bool
    private let isHovered: Bool

    public init(isSelected: Bool, isHovered: Bool) {
        self.isSelected = isSelected
        self.isHovered = isHovered
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: EchoRadius.row, style: .continuous)
            .fill(isSelected ? EchoColor.selection : (isHovered ? EchoColor.hover : .clear))
    }
}
