//
//  InlineHighlight.swift
//  Workspace
//
//  A rounded fill behind some words of a paragraph: code in a summary's prose,
//  a find match in a transcript. An attributed string can colour the
//  background of a run, but only edge to edge and square, and the design
//  draws both with a radius and a little room around the letters. So the run
//  is marked with an attribute and the paragraph is drawn by a renderer that
//  fills each marked run's box first and lays the text over it.
//

import SwiftUI

/// What to draw behind a run: the fill, its radius, and how far it reaches
/// past the run's letters — to the left, to the right, and above and below.
nonisolated struct InlineHighlight: TextAttribute {
    var fill: Color
    var radius: CGFloat
    var leading: CGFloat
    var trailing: CGFloat
    var vertical: CGFloat
}

/// Draws a paragraph's highlights, then its text. Every line's fills go down
/// before any text, so a fill on one line never covers the descenders of the
/// line above it. A run that opens its line — the rest of a highlight that
/// wrapped, or one that starts the paragraph — reaches no further left than
/// its letters, so no fill ever sticks out past the column's edge.
nonisolated struct InlineHighlightRenderer: TextRenderer {

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for (index, run) in line.enumerated() {
                guard let highlight = run[InlineHighlight.self] else { continue }
                let box = run.typographicBounds.rect
                let leading = index == 0 ? 0 : highlight.leading
                let rect = CGRect(
                    x: box.minX - leading,
                    y: box.minY - highlight.vertical,
                    width: box.width + leading + highlight.trailing,
                    height: box.height + 2 * highlight.vertical)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: highlight.radius, style: .continuous),
                    with: .color(highlight.fill))
            }
        }
        for line in layout {
            context.draw(line)
        }
    }
}
