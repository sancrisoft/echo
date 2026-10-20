//
//  LiveSessionFooter.swift
//  Workspace
//
//  The footer under a live session's document: the two channels' levels over
//  the last few seconds, what is happening, and where it happens.
//
//  The levels are the session's own — measured per callback and windowed by
//  the session — read here at a steady pace and drawn as they were read.
//  Nothing is smoothed and nothing is made up: a row starts empty and fills
//  from the right as the session is read, and a bar at rest is a channel that
//  was silent, never a placeholder for one that was not measured.
//

import DesignSystem
import Recording
import SwiftUI

/// The footer, reading the session.
struct LiveSessionFooter: View {
    @Environment(RecordingSession.self) private var session

    @State private var you = LevelTrail()
    @State private var others = LevelTrail()

    /// How often the meter takes a reading: one bar per reading. Not drawn —
    /// the artboard is a still. A tenth of a second a bar puts four seconds on
    /// the meter: long enough to see a sentence go by, short enough to read as
    /// now.
    static let readingInterval: Duration = .milliseconds(100)

    var body: some View {
        LiveFooterBar(you: you.levels, others: others.levels)
            .task {
                while !Task.isCancelled {
                    let levels = session.levels
                    you.record(levels.you)
                    others.record(levels.others)
                    try? await Task.sleep(for: Self.readingInterval)
                }
            }
    }
}

/// A channel's recent levels, oldest first, never more than the meter shows.
struct LevelTrail: Equatable {
    let capacity: Int
    private(set) var levels: [Double] = []

    init(capacity: Int = EchoControl.meterBarCount) {
        self.capacity = capacity
    }

    /// Keeps `level`, clamped to 0…1 — a bar cannot be taller than its row —
    /// and lets the oldest go once the meter is full.
    mutating func record(_ level: Double) {
        levels.append(min(max(level, 0), 1))
        if levels.count > capacity {
            levels.removeFirst(levels.count - capacity)
        }
    }
}

/// The footer, drawn from values.
struct LiveFooterBar: View {
    let you: [Double]
    let others: [Double]

    var body: some View {
        HStack(spacing: EchoLayout.liveFooterGap) {
            VStack(alignment: .leading, spacing: EchoControl.meterLabelGap) {
                Text("You")
                Text("Others")
            }
            .font(EchoFont.meterLabel)
            .tracking(EchoFont.meterLabelTracking)
            .foregroundStyle(EchoColor.textQuaternary)
            .fixedSize()
            .accessibilityHidden(true)

            LevelMeter(you: you, others: others)

            Spacer(minLength: 0)

            Text("Recording…")
                .font(EchoFont.footerStatus)
                .foregroundStyle(EchoColor.accent)
            HStack(spacing: EchoControl.footerGlyphGap) {
                Image(systemName: "shield")
                    .font(.system(size: EchoControl.footerGlyphSize))
                    .accessibilityHidden(true)
                Text("Processed locally")
                    .font(EchoFont.footerNote)
            }
            .foregroundStyle(EchoColor.textTertiary)
        }
        .lineLimit(1)
        .padding(.horizontal, EchoLayout.liveFooterInset)
        .frame(height: EchoLayout.liveFooterHeight)
        .frame(maxWidth: .infinity)
        .background(EchoColor.sidebarBackground)
        .overlay(alignment: .top) {
            EchoColor.divider
                .frame(height: EchoLayout.hairline)
        }
    }
}

/// Two rows of bars, You over Others, the newest at the right edge.
struct LevelMeter: View {
    let you: [Double]
    let others: [Double]

    static var width: CGFloat {
        let count = CGFloat(EchoControl.meterBarCount)
        return count * EchoControl.meterBarWidth + (count - 1) * EchoControl.meterBarGap
    }

    static var height: CGFloat { 2 * EchoControl.meterRowPitch }

    /// A bar's height for a level: at rest when silent, the row's full pitch
    /// at the loudest.
    static func barHeight(_ level: Double) -> CGFloat {
        let clamped = CGFloat(min(max(level, 0), 1))
        return EchoControl.meterBarRest + clamped * (EchoControl.meterRowPitch - EchoControl.meterBarRest)
    }

    var body: some View {
        Canvas { context, size in
            draw(you, centredOn: EchoControl.meterRowPitch / 2, in: size, with: EchoColor.accent, into: &context)
            draw(
                others, centredOn: EchoControl.meterRowPitch * 1.5, in: size, with: EchoColor.levelOthers,
                into: &context)
        }
        .frame(width: Self.width, height: Self.height)
        // One element: the two channels and the newest level of each — the
        // same numbers the newest bars are drawn from.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Levels")
        .accessibilityValue(
            "You \(Self.percent(you.last)), Others \(Self.percent(others.last))")
    }

    private func draw(
        _ levels: [Double], centredOn centre: CGFloat, in size: CGSize, with colour: Color,
        into context: inout GraphicsContext
    ) {
        let pitch = EchoControl.meterBarWidth + EchoControl.meterBarGap
        for (fromNewest, level) in levels.reversed().enumerated() {
            let height = Self.barHeight(level)
            let bar = CGRect(
                x: size.width - EchoControl.meterBarWidth - CGFloat(fromNewest) * pitch,
                y: centre - height / 2,
                width: EchoControl.meterBarWidth,
                height: height)
            context.fill(
                Path(roundedRect: bar, cornerRadius: EchoControl.meterBarWidth / 2), with: .color(colour))
        }
    }

    private static func percent(_ level: Double?) -> String {
        (level ?? 0).formatted(.percent.precision(.fractionLength(0)))
    }
}
