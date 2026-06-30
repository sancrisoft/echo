//
//  WaveformView.swift
//  Echo
//
//  A live bar waveform driven by an array of magnitudes (0...1). Heights
//  animate as new levels scroll in from the right.
//

import SwiftUI

struct WaveformView: View {
    var levels: [CGFloat]
    var color: Color
    var barSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let totalSpacing = barSpacing * CGFloat(count - 1)
            let barWidth = max(1, (geo.size.width - totalSpacing) / CGFloat(count))

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: barHeight(level, in: geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: levels)
        }
    }

    private func barHeight(_ level: CGFloat, in maxHeight: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 3
        return minHeight + level * (maxHeight - minHeight)
    }
}

/// A labeled waveform row used in the popover: an icon, a caption, and the bars.
struct ChannelMeter: View {
    var title: String
    var systemImage: String
    var levels: [CGFloat]
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            WaveformView(levels: levels, color: color)
                .frame(height: 28)
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        ChannelMeter(
            title: "Tú · micrófono",
            systemImage: "mic.fill",
            levels: (0..<28).map { _ in CGFloat.random(in: 0.05...1) },
            color: .blue
        )
        ChannelMeter(
            title: "Equipo · sistema",
            systemImage: "speaker.wave.2.fill",
            levels: (0..<28).map { _ in CGFloat.random(in: 0.05...1) },
            color: .purple
        )
    }
    .padding()
    .frame(width: 300)
}
