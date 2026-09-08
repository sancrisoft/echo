//
//  EchoFont.swift
//  DesignSystem
//
//  The type scale, from the internal design: a document title, a section
//  title, a reading body with generous leading, a compact row, and a micro
//  label. Numbers and identifiers — timers, durations, word counts, model
//  names, shortcuts — use the monospaced face with tabular digits so nothing
//  dances as it ticks.
//
//  System fonts for now; the design's typefaces are bundled in a later step
//  (licences, `ATSApplicationFontsPath`) and change only this file when they land.
//

import SwiftUI

public nonisolated enum EchoFont {

    /// 30/650 — the meeting title at the top of the document.
    public static let documentTitle = Font.system(size: 30, weight: .semibold)

    /// 17/650 — a section heading inside a document or a screen.
    public static let sectionTitle = Font.system(size: 17, weight: .semibold)

    /// 14.5 — reading text: summaries and transcript paragraphs.
    public static let body = Font.system(size: 14.5)

    /// Extra leading for `body` (1.62 line height).
    public static let bodyLineSpacing: CGFloat = 14.5 * 0.62 - 3

    /// 13/500 — list rows and controls.
    public static let row = Font.system(size: 13, weight: .medium)

    /// 13 — secondary lines under a row.
    public static let rowDetail = Font.system(size: 12.5)

    /// 11.5 — micro labels, badges, footers.
    public static let micro = Font.system(size: 11.5)

    /// Monospaced with tabular digits, for anything that counts.
    public static func mono(_ size: CGFloat = 12.5, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced).monospacedDigit()
    }
}
