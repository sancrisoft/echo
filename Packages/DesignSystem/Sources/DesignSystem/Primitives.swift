//
//  Primitives.swift
//  DesignSystem
//
//  The pieces every surface repeats, implemented once: button styles, a status
//  badge, a meta strip, an empty state, and the chrome behind a selectable
//  row. Each takes tokens, never literals, and knows nothing about meetings.
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
        case destructive
    }

    private let role: Role

    public init(_ role: Role = .secondary) {
        self.role = role
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(role == .primary ? EchoFont.primaryButton : EchoFont.control)
            .lineLimit(1)
            .frame(height: height)
            .padding(.horizontal, inset)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed), in: .rect(cornerRadius: radius))
            .overlay {
                if role == .secondary {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(EchoColor.border, lineWidth: 1)
                }
            }
            .contentShape(.rect(cornerRadius: radius))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }

    /// A quiet button is a toolbar button and takes that shape; everything
    /// with a fill takes the shape of the one filled button the design draws,
    /// so buttons on a screen line up whatever their role.
    private var height: CGFloat {
        role == .quiet ? EchoLayout.toolbarButtonHeight : EchoControl.primaryButtonHeight
    }

    private var inset: CGFloat {
        role == .quiet ? EchoControl.toolbarButtonInset : EchoControl.primaryButtonInset
    }

    private var radius: CGFloat {
        role == .quiet ? EchoRadius.row : EchoRadius.control
    }

    private var foreground: Color {
        switch role {
        // The design's one filled button is the interface inverted: the text
        // takes the window's own background, whichever appearance that is.
        case .primary: return EchoColor.windowBackground
        case .secondary: return EchoColor.textPrimary
        case .quiet: return EchoColor.textSecondary
        case .destructive: return EchoColor.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch role {
        // Not the accent. The accent marks selection and links; a button that
        // wore it would be the loudest thing on a grey screen.
        case .primary: return EchoColor.textPrimary.opacity(pressed ? 0.85 : 1)
        case .secondary: return EchoColor.surfaceRaised.opacity(pressed ? 0.7 : 1)
        case .quiet: return pressed ? EchoColor.hover : .clear
        case .destructive: return EchoColor.danger.opacity(pressed ? 0.16 : 0.1)
        }
    }
}

extension ButtonStyle where Self == EchoButtonStyle {
    public static var echoPrimary: EchoButtonStyle { EchoButtonStyle(.primary) }
    public static var echoSecondary: EchoButtonStyle { EchoButtonStyle(.secondary) }
    public static var echoQuiet: EchoButtonStyle { EchoButtonStyle(.quiet) }
    public static var echoDestructive: EchoButtonStyle { EchoButtonStyle(.destructive) }
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

    public init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text)
            .font(EchoFont.statusPill)
            .foregroundStyle(color)
            .padding(.horizontal, EchoControl.pillInset.width)
            .padding(.vertical, EchoControl.pillInset.height)
            .background(fill, in: .rect(cornerRadius: EchoRadius.pill))
            .lineLimit(1)
            .fixedSize()
    }

    /// The design draws one of these: the accent pill, on the accent's own
    /// wash. The other tones are states it has not drawn, and they borrow the
    /// wash's weight rather than inventing one.
    private var fill: Color {
        tone == .accent ? EchoColor.accentWash : color.opacity(0.15)
    }

    private var color: Color {
        switch tone {
        case .neutral: return EchoColor.textSecondary
        case .accent: return EchoColor.accent
        case .success: return EchoColor.success
        case .warning: return EchoColor.warning
        case .danger: return EchoColor.danger
        case .recording: return EchoColor.recording
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

// MARK: - Meta strip

/// One fact in a `MetaStrip`: an SF Symbol and its text.
public struct MetaItem: Identifiable, Sendable {
    public let id: String
    public let symbol: String
    public let text: String

    public init(_ symbol: String, _ text: String) {
        self.id = symbol + text
        self.symbol = symbol
        self.text = text
    }
}

/// A row of small facts under a title: date, duration, word count, status.
public struct MetaStrip: View {
    private let items: [MetaItem]

    public init(_ items: [MetaItem]) {
        self.items = items
    }

    public var body: some View {
        HStack(spacing: EchoSpacing.l) {
            ForEach(items) { item in
                HStack(spacing: EchoSpacing.xs) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 11))
                    Text(item.text)
                        .font(EchoFont.control)
                        .monospacedDigit()
                }
                .foregroundStyle(EchoColor.textSecondary)
                .lineLimit(1)
            }
        }
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
