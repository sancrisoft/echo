//
//  WaveformView.swift
//  Echo
//
//  The recording popover's live waveform: two overlapping traveling sine waves.
//  The indigo wave (front) is the microphone — the user; the gray wave (behind)
//  is the system stream — teammates. The horizontal travel is a cosmetic
//  animation, but each wave's *amplitude* is driven by the real per-channel
//  capture level (never simulated data), so a silent channel collapses toward a
//  gentle resting line and a loud one swells to fill the card.
//

import SwiftUI

extension Color {
    /// Echo's indigo brand accent — the app glyph, the mic wave, and the
    /// Start button all share it so the popover reads as one system.
    static let echoIndigo = Color(red: 0.36, green: 0.37, blue: 0.96)
}

struct DualWaveView: View {
    /// Current microphone amplitude, 0...1 (real capture level — the user).
    var inputLevel: CGFloat
    /// Current system amplitude, 0...1 (real capture level — teammates).
    var outputLevel: CGFloat

    /// A single display amplitude (0...1) from a channel's rolling levels: the
    /// mean of the most recent samples, lightly gained so ordinary speech reads
    /// as a visible wave. Still entirely real capture data. Shared by every
    /// surface that renders these waves (menu bar popover, live detail footer).
    static func amplitude(_ levels: [CGFloat]) -> CGFloat {
        guard !levels.isEmpty else { return 0 }
        let recent = levels.suffix(8)
        let mean = recent.reduce(0, +) / CGFloat(recent.count)
        return min(1, mean * 1.4)
    }

    var body: some View {
        // `.animation` gives a per-frame date; only the phase advances with it,
        // so the waves travel while their height stays tied to real levels.
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                // Behind: teammates / system audio (gray).
                drawWave(
                    in: &context, size: size,
                    amplitude: outputLevel, phase: t * 1.7, frequency: 2.1,
                    color: Color(white: 0.74), lineWidth: 2.5
                )
                // Front: the user / microphone (indigo).
                drawWave(
                    in: &context, size: size,
                    amplitude: inputLevel, phase: t * 2.3 + 0.7, frequency: 2.6,
                    color: .echoIndigo, lineWidth: 3
                )
            }
        }
    }

    private func drawWave(
        in context: inout GraphicsContext,
        size: CGSize,
        amplitude: CGFloat,
        phase: Double,
        frequency: Double,
        color: Color,
        lineWidth: CGFloat
    ) {
        let midY = size.height / 2
        let clamped = min(max(amplitude, 0), 1)
        // A small floor keeps a silent channel legible as a resting line; the
        // ceiling leaves room for the stroke so a loud burst never clips.
        let maxAmp = midY - lineWidth
        let amp = maxAmp * (0.07 + 0.93 * clamped)

        var path = Path()
        let step: CGFloat = 2
        var x: CGFloat = 0
        while x <= size.width {
            let rel = Double(x / max(size.width, 1))
            let y = midY + CGFloat(sin(rel * .pi * 2 * frequency + phase)) * amp
            if x == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
            x += step
        }

        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
    }
}

#Preview {
    VStack(spacing: 20) {
        DualWaveView(inputLevel: 0.7, outputLevel: 0.35)
            .frame(height: 54)
        DualWaveView(inputLevel: 0.05, outputLevel: 0.05)
            .frame(height: 54)
    }
    .padding()
    .frame(width: 300)
    .background(Color(white: 0.97))
}
