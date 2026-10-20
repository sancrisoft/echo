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
        /// A row's action that removes something for good — Trash's Delete
        /// and Empty Trash: the control button outlined in the failure's edge,
        /// its words in the destructive red, and no fill (product owner,
        /// 2026-10-20).
        case controlDestructive
        /// A row's action inside a list row — Trash's Restore. Selected, the
        /// row takes the control's own raised fill, so the button keeps that
        /// fill and draws a darker edge to still read as a button (product
        /// owner, 2026-10-20: a white button on the selected row was too
        /// abrupt a change).
        case controlInRow
        /// A quiet button that removes something for good — a trashed
        /// meeting's Delete in the breadcrumb bar: the quiet button in the
        /// destructive red.
        case quietDestructive
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
    /// and the title bar's New recording takes the same look, as does the
    /// empty library's. A held-back button keeps its shape and size and is
    /// drawn on a raised grey fill with an inert edge and the quaternary
    /// label, so no screen changes its layout while it explains why. The
    /// control button already wears that fill and edge, and held back — the
    /// Re-transcribe of a meeting whose audio is gone, with its reason —
    /// only its label greys. The other roles have no decided held-back look
    /// and keep the one they have.
    private struct Drawn: View {
        let configuration: Configuration
        let role: Role

        @Environment(\.isEnabled) private var isEnabled

        private var isHeldBack: Bool {
            switch role {
            case .primary, .prominent, .controlProminent, .control: return !isEnabled
            case .secondary, .quiet, .quietIcon, .quietDestructive, .destructive, .controlDestructive,
                .controlInRow:
                return false
            }
        }

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
            case .secondary, .quiet, .quietIcon, .quietDestructive, .destructive, .control, .controlDestructive,
                .controlInRow:
                return EchoFont.control
            }
        }

        private var height: CGFloat {
            switch role {
            case .quiet, .quietIcon, .quietDestructive: return EchoLayout.toolbarButtonHeight
            case .control, .controlProminent, .controlDestructive, .controlInRow:
                return EchoControl.controlButtonHeight
            case .prominent: return EchoControl.prominentButtonHeight
            case .primary, .secondary, .destructive: return EchoControl.primaryButtonHeight
            }
        }

        private var inset: CGFloat {
            switch role {
            case .quiet, .quietDestructive: return EchoControl.toolbarButtonInset
            case .quietIcon: return 0
            case .control, .controlProminent, .controlDestructive, .controlInRow:
                return EchoControl.controlButtonInset
            case .prominent: return EchoControl.prominentButtonInset
            case .primary, .secondary, .destructive: return EchoControl.primaryButtonInset
            }
        }

        private var radius: CGFloat {
            switch role {
            case .quiet, .quietIcon, .quietDestructive, .control, .controlProminent, .controlDestructive,
                .controlInRow:
                return EchoRadius.row
            case .primary, .secondary, .destructive, .prominent: return EchoRadius.control
            }
        }

        private var edge: Color? {
            if isHeldBack { return EchoColor.inertBorder }
            switch role {
            case .secondary: return EchoColor.border
            case .control: return EchoColor.inertBorder
            case .controlInRow: return EchoColor.controlEdgeInRow
            case .controlDestructive: return EchoColor.failureEdge
            case .primary, .quiet, .quietIcon, .quietDestructive, .destructive, .controlProminent, .prominent:
                return nil
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
            case .control, .controlInRow: return EchoColor.textValue
            case .controlDestructive, .quietDestructive: return EchoColor.destructiveText
            }
        }

        private func background(pressed: Bool) -> Color {
            if isHeldBack { return EchoColor.surfaceRaised }
            switch role {
            // Not the accent. The accent marks selection and links; a button
            // that wore it would be the loudest thing on a grey screen.
            case .primary, .controlProminent, .prominent: return EchoColor.textPrimary.opacity(pressed ? 0.85 : 1)
            case .secondary, .control, .controlInRow: return EchoColor.surfaceRaised.opacity(pressed ? 0.7 : 1)
            case .quiet, .quietIcon, .quietDestructive, .controlDestructive: return pressed ? EchoColor.hover : .clear
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
    public static var echoControlDestructive: EchoButtonStyle { EchoButtonStyle(.controlDestructive) }
    public static var echoControlInRow: EchoButtonStyle { EchoButtonStyle(.controlInRow) }
    public static var echoQuietDestructive: EchoButtonStyle { EchoButtonStyle(.quietDestructive) }
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

// MARK: - Keys

/// A key as the artboards draw one: its name in mono on a hairline outline.
/// In a row of hints it sits tight; on its own — the palette's `esc`, a
/// shortcut beside an action — it gets a little more room, and on the row
/// the keyboard is on it is drawn a step stronger.
public struct Keycap: View {

    public enum Size: Sendable {
        case hint
        case standalone
    }

    private let key: String
    private let size: Size
    private let isEmphasized: Bool

    public init(_ key: String, size: Size = .standalone, isEmphasized: Bool = false) {
        self.key = key
        self.size = size
        self.isEmphasized = isEmphasized
    }

    public var body: some View {
        let inset = size == .hint ? EchoControl.keycapInset : EchoControl.keycapInsetStandalone
        Text(key)
            .font(EchoFont.mono(10.5))
            .foregroundStyle(isEmphasized ? EchoColor.textTertiary : EchoColor.textQuaternary)
            .padding(.horizontal, inset.width)
            .padding(.vertical, inset.height)
            .overlay {
                RoundedRectangle(cornerRadius: EchoRadius.keycap)
                    .strokeBorder(
                        isEmphasized ? EchoColor.paletteBorder : EchoColor.inertBorder, lineWidth: EchoLayout.hairline)
            }
            .fixedSize()
    }
}

/// A key and what it does, as a footer of hints draws them: Trash's, and the
/// palette's.
public struct KeyHint: View {
    private let key: String
    private let label: String

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }

    public var body: some View {
        HStack(spacing: EchoLayout.keyHintGap) {
            Keycap(key, size: .hint)
            Text(label)
                .font(EchoFont.micro)
                .foregroundStyle(EchoColor.textQuaternary)
        }
        .fixedSize()
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

/// A screen with nothing to show, as the empty-states artboard draws it: the
/// glyph for why, what happened, a sentence, and the one action that gets the
/// user out of it — a dead end with no button is a bug, not a state. Only
/// an empty Trash has nothing to offer, and it takes no actions.
///
/// Bare and centred in whatever holds it (product owner, 2026-10-20): the
/// artboard's cards are the frames of its sheet, not part of the state.
public struct EmptyState<Actions: View>: View {
    private let glyph: EmptyGlyph
    private let title: String
    private let message: String
    private let actions: Actions

    public init(glyph: EmptyGlyph, title: String, message: String, @ViewBuilder actions: () -> Actions) {
        self.glyph = glyph
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: EchoLayout.emptyStateGap) {
            EmptyGlyphShape(glyph)
                .stroke(
                    glyph == .warning ? EchoColor.failureGlyph : EchoColor.placeholderGlyph,
                    style: StrokeStyle(
                        lineWidth: EmptyGlyph.lineWidth(at: EchoControl.emptyGlyphSize), lineCap: .round,
                        lineJoin: .round)
                )
                .frame(width: EchoControl.emptyGlyphSize, height: EchoControl.emptyGlyphSize)
                .accessibilityHidden(true)
            Text(title)
                .font(EchoFont.emptyTitle)
                .foregroundStyle(EchoColor.textValue)
                .multilineTextAlignment(.center)
            Text(message)
                .font(EchoFont.emptyMessage)
                .lineSpacing(EchoFont.emptyMessageLineSpacing)
                .foregroundStyle(EchoColor.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: EchoLayout.emptyStateMessageWidth)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: EchoLayout.emptyStateActionGap) {
                actions
            }
        }
        .padding(EchoLayout.emptyStateInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyState where Actions == EmptyView {
    public init(glyph: EmptyGlyph, title: String, message: String) {
        self.init(glyph: glyph, title: title, message: message) { EmptyView() }
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
