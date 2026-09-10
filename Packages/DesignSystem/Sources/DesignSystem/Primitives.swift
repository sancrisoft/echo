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
            .font(EchoFont.row)
            .padding(.horizontal, role == .quiet ? EchoSpacing.s : EchoSpacing.m)
            .padding(.vertical, 6)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed), in: .rect(cornerRadius: EchoRadius.control))
            .overlay {
                if role == .secondary {
                    RoundedRectangle(cornerRadius: EchoRadius.control)
                        .strokeBorder(EchoColor.border, lineWidth: 1)
                }
            }
            .contentShape(.rect(cornerRadius: EchoRadius.control))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }

    private var foreground: Color {
        switch role {
        case .primary: return .white
        case .secondary: return EchoColor.textPrimary
        case .quiet: return EchoColor.textSecondary
        case .destructive: return EchoColor.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch role {
        case .primary: return EchoColor.accent.opacity(pressed ? 0.8 : 1)
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

    public enum Tone: Sendable {
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
            .font(EchoFont.micro.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: .capsule)
            .lineLimit(1)
            .fixedSize()
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
