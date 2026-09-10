//
//  IslandControls.swift
//  DesignSystem
//
//  The island's controls: a capsule in three roles, a value chip, an icon
//  button and a level gauge. A family of their own, not a variant of the
//  window's buttons — the island takes iOS-style capsules while the window
//  keeps rounded rects at its own radius, and whether those two ever become
//  one is a design decision that is still open. Until it is made, the two
//  families stay apart and neither borrows the other's geometry.
//
//  Everything here is drawn on black, at a percentage of white rather than a
//  grey, so a control reads the same over the shell and over the wallpaper the
//  flares expose. Only the weight of a label separates a primary from a
//  secondary: there are no white capsules on the island.
//

import SwiftUI

// MARK: - Capsules

/// The island's button family. At most one primary per face; the order along a
/// face is quiet, then secondary, then primary.
public struct IslandButtonStyle: ButtonStyle {

    public enum Role: Sendable {
        /// The action the face exists to offer. Filled, and the heavier label.
        case primary
        /// An action worth offering beside it. The same fill, a lighter label.
        case secondary
        /// An action that should not compete. No fill at all.
        case quiet
    }

    private let role: Role

    public init(_ role: Role = .secondary) {
        self.role = role
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(role == .primary ? EchoFont.capsulePrimary : EchoFont.capsuleSecondary)
            .tracking(EchoFont.capsuleTracking)
            .foregroundStyle(
                role == .quiet ? EchoColor.Island.quietLabel : EchoColor.Island.controlLabel
            )
            .lineLimit(1)
            .frame(height: EchoControl.capsuleHeight)
            .padding(.horizontal, inset)
            .background(fill, in: .rect(cornerRadius: EchoRadius.capsule))
            .contentShape(.rect(cornerRadius: EchoRadius.capsule))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }

    private var inset: CGFloat {
        switch role {
        case .primary: EchoControl.capsuleInset
        case .secondary: EchoControl.capsuleInsetSecondary
        case .quiet: EchoControl.capsuleInsetQuiet
        }
    }

    private var fill: Color {
        role == .quiet ? .clear : EchoColor.Island.controlFill
    }
}

extension ButtonStyle where Self == IslandButtonStyle {
    public static var islandPrimary: IslandButtonStyle { IslandButtonStyle(.primary) }
    public static var islandSecondary: IslandButtonStyle { IslandButtonStyle(.secondary) }
    public static var islandQuiet: IslandButtonStyle { IslandButtonStyle(.quiet) }
}

/// A square, fully rounded button holding one glyph — the ✕ that dismisses a
/// face. Quieter than a capsule: it takes the chip's fill, not the control's.
public struct IslandIconButtonStyle: ButtonStyle {

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: EchoControl.islandGlyphSize, weight: .medium))
            .foregroundStyle(EchoColor.Island.glyph)
            .frame(width: EchoControl.iconButtonSize, height: EchoControl.iconButtonSize)
            .background(EchoColor.Island.chipFill, in: .rect(cornerRadius: EchoRadius.chip))
            .contentShape(.rect(cornerRadius: EchoRadius.chip))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

extension ButtonStyle where Self == IslandIconButtonStyle {
    public static var islandIcon: IslandIconButtonStyle { IslandIconButtonStyle() }
}

// MARK: - Value chip

/// A control that shows the value it would change — the capture selector on
/// the idle face reads "Everything ▾". Shorter than a capsule and inset less
/// on the chevron's side, so the arrow sits closer to the edge than the word
/// does.
public struct ValueChip: View {

    private let value: String
    private let action: () -> Void

    public init(_ value: String, action: @escaping () -> Void) {
        self.value = value
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: EchoControl.chipGap) {
                Text(value)
                    .font(EchoFont.chip)
                    .foregroundStyle(EchoColor.Island.controlLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: EchoControl.islandGlyphSize, weight: .semibold))
                    .foregroundStyle(EchoColor.Island.quietLabel)
            }
            .frame(height: EchoControl.chipHeight)
            .padding(.leading, EchoControl.chipLeadingInset)
            .padding(.trailing, EchoControl.chipTrailingInset)
            .background(EchoColor.Island.chipFill, in: .rect(cornerRadius: EchoRadius.chip))
            .contentShape(.rect(cornerRadius: EchoRadius.chip))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Level gauge

/// One capture level: a label and a bar that is filled to exactly the fraction
/// it was handed.
///
/// It does no smoothing, no decay and no averaging of its own. Whatever windows
/// the raw callbacks does it before this, and what arrives here is drawn — so
/// two gauges side by side always show the same instant, and a level on screen
/// is a level that was measured.
public struct LevelGauge: View {

    /// Which of the two the design draws: the accent one, or the neutral one
    /// beside it.
    public enum Tone: Sendable {
        case accent
        case neutral
    }

    private let label: String
    private let level: Double
    private let tone: Tone

    /// - Parameter level: 0…1. Values outside it are clamped, because a bar
    ///   cannot be longer than itself — never scaled, so the number drawn stays
    ///   the number given.
    public init(_ label: String, level: Double, tone: Tone) {
        self.label = label
        self.level = min(max(level, 0), 1)
        self.tone = tone
    }

    public var body: some View {
        HStack(spacing: EchoControl.gaugeLabelGap) {
            Text(label)
                .font(EchoFont.gaugeLabel)
                .tracking(EchoFont.gaugeLabelTracking)
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .fixedSize()
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: EchoRadius.gauge, style: .continuous)
                        .fill(EchoColor.Island.gaugeTrack)
                    RoundedRectangle(cornerRadius: EchoRadius.gauge, style: .continuous)
                        .fill(fillColor)
                        .frame(width: proxy.size.width * level)
                }
            }
            .frame(height: EchoControl.gaugeHeight)
        }
    }

    private var labelColor: Color {
        switch tone {
        case .accent: EchoColor.accent
        case .neutral: EchoColor.Island.gaugeNeutralLabel
        }
    }

    private var fillColor: Color {
        switch tone {
        case .accent: EchoColor.accent
        case .neutral: EchoColor.Island.gaugeNeutral
        }
    }
}
