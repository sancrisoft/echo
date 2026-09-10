//
//  EchoFont.swift
//  DesignSystem
//
//  The type scale, and the one place the two bundled typefaces are named.
//  Onest says everything the interface says; DM Mono is only for numbers and
//  identifiers — timers, durations, word counts, model names, shortcuts — so a
//  running timer does not dance as its digits change.
//
//  Both files ship inside this package (`Resources/Fonts`, SIL OFL 1.1) and are
//  registered with the process at launch by `registerBundledTypefaces()`. If
//  that fails, or if a host never calls it, every token falls back to the
//  system faces the design names as its fallback: SF Pro for the interface,
//  SF Mono for the numbers. Nothing else in the app names a typeface, so that
//  fallback is one decision made here.
//
//  Two ways of building a font, for one reason. A token at a weight the family
//  ships as a named instance is built with `Font.custom`, because SwiftUI can
//  still re-weight it — `EchoFont.body.weight(.semibold)` works. A token at a
//  weight between the named instances (the design's 650) has to be built from
//  an `NSFont` positioned on Onest's variable axis, and SwiftUI ignores
//  `.weight()` on those: ask for the token you want instead of adjusting one.
//

import AppKit
import CoreText
import SwiftUI

public nonisolated enum EchoFont {

    // MARK: - The scale
    //
    // Sizes and weights are the design's, one token per role it names. A view
    // that needs a size the design has not drawn is a view drawing something
    // the design has not drawn.

    /// 30 / 650 — the meeting title at the top of a document, and the title of
    /// Trash and Settings.
    public static var documentTitle: Font { onest(30, weight: 650) }

    /// 17 / 650 — a section heading inside a document or a screen.
    public static var sectionTitle: Font { onest(17, weight: 650) }

    /// 14.5 — reading text: summary paragraphs and transcript turns.
    public static var body: Font { onest(14.5, weight: 400) }

    /// 14.5 / 600 — bold inside prose.
    public static var bodyBold: Font { onest(14.5, weight: 600) }

    /// 13.5 — the value of a property row under the title.
    public static var propertyValue: Font { onest(13.5, weight: 400) }

    /// 12.5 — the label of a property row.
    public static var propertyLabel: Font { onest(12.5, weight: 400) }

    /// 13 — a row in the sidebar.
    public static var row: Font { onest(13, weight: 400) }

    /// 13 / 500 — the same row, selected.
    public static var rowSelected: Font { onest(13, weight: 500) }

    /// 13.5 / 600 — "Echo" at the top of the sidebar.
    public static var appName: Font { onest(13.5, weight: 600) }

    /// 11.5 / 600 — a section label in the sidebar ("Meetings").
    public static var sectionLabel: Font { onest(11.5, weight: 600) }

    /// 11 — a date group's header (Today, Yesterday, Last week, Earlier).
    public static var groupHeader: Font { onest(11, weight: 400) }

    /// 12.5 — a control: the breadcrumb, a toolbar button, a tab.
    public static var control: Font { onest(12.5, weight: 400) }

    /// 12.5 / 500 — the selected tab of a strip.
    public static var controlSelected: Font { onest(12.5, weight: 500) }

    /// 12 / 500 — the status pill.
    public static var statusPill: Font { onest(12, weight: 500) }

    /// 12.5 / 600 — the label of the one filled button a screen gets.
    public static var primaryButton: Font { onest(12.5, weight: 600) }

    /// 11.5 — the smallest size the design sets words at. Numbers and
    /// identifiers at this size go through `mono` instead.
    public static var micro: Font { onest(11.5, weight: 400) }

    // The island sets its own controls: a capsule, a value chip and the label
    // beside a level gauge. They are smaller and tighter than anything in the
    // window, because they hang off the bezel with the wallpaper behind them.

    /// 12 / 600 — the label of a primary capsule.
    public static var capsulePrimary: Font { onest(12, weight: 600) }

    /// 12 / 500 — the label of a secondary capsule, and of a quiet one: the
    /// design separates primary from the rest by weight alone.
    public static var capsuleSecondary: Font { onest(12, weight: 500) }

    /// 11.5 / 500 — the label of a value chip.
    public static var chip: Font { onest(11.5, weight: 500) }

    /// 10 / 600 — the label beside a level gauge.
    public static var gaugeLabel: Font { onest(10, weight: 600) }

    /// Monospaced with tabular digits, for anything that counts. The design
    /// draws it at 500 for a timer, 400 for inline code and a model name, and
    /// 300 nowhere yet — the three weights DM Mono ships.
    public static func mono(_ size: CGFloat = 12.5, weight: Font.Weight = .regular) -> Font {
        guard let name = monoPostScriptName(for: weight), NSFont(name: name, size: size) != nil else {
            return .system(size: size, weight: weight, design: .monospaced).monospacedDigit()
        }
        return .custom(name, fixedSize: size).monospacedDigit()
    }

    // MARK: - Leading and tracking
    //
    // SwiftUI carries these on the `Text`, not on the `Font`, so they are
    // tokens of their own. The design states tracking in em; these are the
    // points that em works out to at each token's size.

    /// Extra leading for `body` (1.62 line height).
    public static let bodyLineSpacing: CGFloat = 14.5 * 0.62 - 3

    /// Extra leading for a transcript turn (1.7 line height).
    public static let transcriptLineSpacing: CGFloat = 14.5 * 0.70 - 3

    /// −0.028em on the document title.
    public static let documentTitleTracking: CGFloat = 30 * -0.028

    /// −0.014em on a section heading.
    public static let sectionTitleTracking: CGFloat = 17 * -0.014

    /// −0.008em on the app name.
    public static let appNameTracking: CGFloat = 13.5 * -0.008

    /// +0.01em on a section label.
    public static let sectionLabelTracking: CGFloat = 11.5 * 0.01

    /// −0.004em on a capsule's label.
    public static let capsuleTracking: CGFloat = 12 * -0.004

    /// −0.004em on a gauge's label.
    public static let gaugeLabelTracking: CGFloat = 10 * -0.004

    // MARK: - The typefaces

    /// Onest's family name, once registered.
    public static let interfaceFamily = "Onest"

    /// DM Mono's typographic family name, once registered. Its three weights
    /// register as three families of their own, so a weight is asked for by
    /// PostScript name.
    public static let monospaceFamily = "DM Mono"

    /// What registering the bundled typefaces did. Empty failures means both
    /// families are available to the process.
    public struct TypefaceRegistration: Sendable {
        /// The files that registered, or were already registered.
        public let registered: [String]
        /// The files that did not, with what CoreText said about each.
        public let failures: [(file: String, reason: String)]

        public var isComplete: Bool { failures.isEmpty }
    }

    /// Registers Onest and DM Mono with this process.
    ///
    /// A launch side effect: the composition root calls it once from `start()`,
    /// before anything renders, and traces whatever it reports. Calling it
    /// again is harmless — CoreText answers "already registered", which is
    /// counted as success — but it does the work once and remembers.
    @MainActor
    @discardableResult
    public static func registerBundledTypefaces() -> TypefaceRegistration {
        if let done = registration { return done }
        var registered: [String] = []
        var failures: [(file: String, reason: String)] = []

        for file in bundledTypefaceFiles {
            guard
                let url = Bundle.module.url(
                    forResource: file, withExtension: "ttf", subdirectory: "Fonts")
            else {
                failures.append((file: file + ".ttf", reason: "not in the package's resources"))
                continue
            }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                registered.append(file)
            } else if let error, CFErrorGetCode(error.takeUnretainedValue()) == alreadyRegistered {
                registered.append(file)
            } else {
                let reason =
                    error.map { CFErrorCopyDescription($0.takeUnretainedValue()) as String }
                    ?? "CoreText refused the file and said nothing"
                failures.append((file: file + ".ttf", reason: reason))
            }
        }

        let result = TypefaceRegistration(registered: registered, failures: failures)
        registration = result
        return result
    }

    /// `kCTFontManagerErrorAlreadyRegistered`, which is not a failure.
    private static let alreadyRegistered: CFIndex = 105

    /// The files in `Resources/Fonts`, without their extension.
    private static let bundledTypefaceFiles = [
        "Onest-VariableFont_wght",
        "DMMono-Light",
        "DMMono-Regular",
        "DMMono-Medium",
    ]

    @MainActor private static var registration: TypefaceRegistration?

    // MARK: - Building a font

    /// Onest at an exact weight on its variable axis.
    ///
    /// The named instances go through `Font.custom` so SwiftUI can still
    /// re-weight them; anything between two instances is positioned on the
    /// axis by hand, because `Font.custom(_:fixedSize:).weight(_:)` can only
    /// reach a named one.
    static func onest(_ size: CGFloat, weight: Double) -> Font {
        guard NSFont(name: interfacePostScriptName, size: size) != nil else {
            return .system(size: size, weight: systemWeight(nearest: weight))
        }
        if let named = namedWeight(weight) {
            return .custom(interfaceFamily, fixedSize: size).weight(named)
        }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: interfaceFamily,
            NSFontDescriptor.AttributeName.variation: [weightAxis: weight],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size) else {
            return .system(size: size, weight: systemWeight(nearest: weight))
        }
        return Font(font)
    }

    /// Onest's regular instance, the cheapest proof the family is registered.
    private static let interfacePostScriptName = "Onest-Regular"

    /// The `wght` axis, as CoreText identifies it.
    private static let weightAxis = 0x7767_6874

    /// The named instances a `Font.Weight` can reach.
    static func namedWeight(_ weight: Double) -> Font.Weight? {
        switch weight {
        case 100: .ultraLight
        case 200: .thin
        case 300: .light
        case 400: .regular
        case 500: .medium
        case 600: .semibold
        case 700: .bold
        case 800: .heavy
        case 900: .black
        default: nil
        }
    }

    /// The system weight that stands in for a design weight when Onest is not
    /// there. SF Pro has no 650, so the design's two headings land on
    /// semibold, the nearest it ships.
    static func systemWeight(nearest weight: Double) -> Font.Weight {
        switch weight {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        // 650 sits exactly between semibold and bold. The design's headings
        // are a heading, not a shout: they round down.
        case ..<680: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }

    /// DM Mono ships three weights; the design uses them by number.
    private static func monoPostScriptName(for weight: Font.Weight) -> String? {
        switch weight {
        case .ultraLight, .thin, .light: "DMMono-Light"
        case .regular: "DMMono-Regular"
        case .medium, .semibold, .bold, .heavy, .black: "DMMono-Medium"
        default: nil
        }
    }
}
