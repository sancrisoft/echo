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
//  The amplitudes arrive already derived: `RecordingState` averages each
//  channel over the same span of *audio* (`levelWindow`), which is what makes
//  the two waves comparable across taps that fire at very different rates.
//  This view decides only how those heights move between readings —
//  see `GlidingLevel`, which is what keeps the slow channel from rendering as
//  a ten-frames-per-second slideshow next to the fast one.
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

    /// Per-channel glides (see `GlidingLevel`): the screen redraws ~10x more
    /// often than the mic reports, so the indigo wave is drawn between
    /// readings rather than held still until the next one lands.
    @State private var input = GlidingLevel()
    @State private var output = GlidingLevel()

    var body: some View {
        // `.animation` gives a per-frame date: the phase advances with it, and
        // each height is the glide's position at that same instant — so every
        // frame draws something new no matter how slowly the levels arrive.
        TimelineView(.animation) { timeline in
            let now = timeline.date
            let t = now.timeIntervalSinceReferenceDate
            Canvas { context, size in
                // Behind: teammates / system audio (gray).
                drawWave(
                    in: &context, size: size,
                    amplitude: output.value(at: now), phase: t * 1.7, frequency: 2.1,
                    color: Color(white: 0.74), lineWidth: 2.5
                )
                // Front: the user / microphone (indigo).
                drawWave(
                    in: &context, size: size,
                    amplitude: input.value(at: now), phase: t * 2.3 + 0.7, frequency: 2.6,
                    color: .echoIndigo, lineWidth: 3
                )
            }
        }
        .onChange(of: inputLevel) { _, level in input.retarget(level) }
        .onChange(of: outputLevel) { _, level in output.retarget(level) }
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

/// Carries one wave's height *between* the readings that feed it.
///
/// The two channels report at very different rates — system audio every ~12 ms,
/// the mic every 100 ms (macOS clamps the tap, see `MicrophoneCapture`) — while
/// the display redraws 60–120 times a second. Painting the raw value means the
/// gray wave gets a fresh height almost every frame and looks fluid, while the
/// indigo one holds the same height for six to twelve frames and then jumps:
/// identical drawing code, visibly worse motion. So instead of snapping to each
/// new reading, the height slides to it over the time the *next* reading is
/// expected to take — measured from the gap between the last two, never assumed,
/// so each channel self-tunes and the fast one is left essentially untouched.
///
/// Motion starts the instant a reading lands (the slide begins immediately);
/// only the peak arrives a beat later, which is the trade that buys continuous
/// movement instead of a ten-frames-per-second slideshow.
struct GlidingLevel {

    /// Bounds on the slide. The floor keeps a burst of near-simultaneous
    /// readings from dividing by ~zero; the ceiling means a channel that
    /// stalls can't leave the wave crawling toward a stale target.
    private static let minimumSlide: TimeInterval = 0.008
    private static let maximumSlide: TimeInterval = 0.12

    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var startedAt: Date = .distantPast
    private var previousReadingAt: Date?
    private var slide: TimeInterval = maximumSlide

    /// Points the glide at a newly reported level, starting from wherever the
    /// wave is drawn right now (never from the previous *target*, which would
    /// jump on a reading that lands mid-slide).
    mutating func retarget(_ level: CGFloat, now: Date = Date()) {
        from = value(at: now)
        to = level
        if let previousReadingAt {
            slide = min(max(now.timeIntervalSince(previousReadingAt), Self.minimumSlide), Self.maximumSlide)
        }
        previousReadingAt = now
        startedAt = now
    }

    /// The height to draw at `now`.
    func value(at now: Date) -> CGFloat {
        guard slide > 0 else { return to }
        let progress = min(max(now.timeIntervalSince(startedAt) / slide, 0), 1)
        return from + (to - from) * CGFloat(progress)
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
