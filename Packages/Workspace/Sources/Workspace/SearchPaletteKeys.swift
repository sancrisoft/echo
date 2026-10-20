//
//  SearchPaletteKeys.swift
//  Workspace
//
//  The palette's keyboard. Its query field keeps the focus the whole time,
//  and the keys that walk the list — ↑ ↓, Tab, Return, ⌘1–⌘9, ⌘C, Esc — are
//  keys a text field takes for itself: moving the caret, moving the focus,
//  ending the edit. So a local monitor reads them first, in the palette's
//  window only, and lets every other key through to the field — typing,
//  ⌘A, ⌘V, and ⌘C itself while words in the field are selected. What a key
//  means is a pure rule, testable without a window.
//

import AppKit

/// What a key does in the palette.
enum PaletteKey: Equatable, Sendable {
    /// ↑ and ↓.
    case move(Int)
    /// Return opens the row the keyboard is on; ⌘Return opens a result on
    /// its other tab.
    case open(otherTab: Bool)
    /// Tab and ⇧Tab step through the scopes.
    case stepScope(Int)
    /// ⌘1–⌘9.
    case openResult(number: Int)
    /// ⌘C: the highlighted meeting's summary.
    case copySummary
    case escape

    /// The Carbon key codes, which name a key wherever it sits on the
    /// keyboard's layout.
    private enum Code {
        static let returnKey: UInt16 = 36
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
        static let keypadEnter: UInt16 = 76
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    /// What a key-down means, or `nil` for a key the field should have. Only
    /// the four modifiers a person presses count; the arrows' own function
    /// and keypad flags do not.
    static func classify(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> PaletteKey? {
        let pressed = modifiers.intersection([.command, .shift, .option, .control])
        switch keyCode {
        case Code.up where pressed.isEmpty: return .move(-1)
        case Code.down where pressed.isEmpty: return .move(1)
        case Code.returnKey, Code.keypadEnter:
            if pressed.isEmpty { return .open(otherTab: false) }
            return pressed == .command ? .open(otherTab: true) : nil
        case Code.tab:
            if pressed.isEmpty { return .stepScope(1) }
            return pressed == .shift ? .stepScope(-1) : nil
        case Code.escape where pressed.isEmpty: return .escape
        default: break
        }
        guard pressed == .command, let characters, characters.count == 1, let character = characters.first,
            character.isASCII
        else { return nil }
        if let digit = character.wholeNumberValue, (1...9).contains(digit) { return .openResult(number: digit) }
        return character == "c" ? .copySummary : nil
    }
}

/// Reads the palette's keys before its field does, while the palette is up.
@MainActor
final class PaletteKeyWatcher {

    /// The window the palette is in. A key pressed in any other window of
    /// the app is not the palette's.
    weak var window: NSWindow?

    /// Answers a key; `false` lets it through to the field.
    var onKey: ((PaletteKey) -> Bool)?

    private var monitor: Any?

    /// Idempotent, so a palette that appears twice installs one monitor.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let swallowed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, event.window === window,
                    let key = PaletteKey.classify(
                        keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                        modifiers: event.modifierFlags)
                else { return false }
                // ⌘C with words selected in the field copies the words.
                if key == .copySummary, Self.fieldHasSelection(in: window) { return false }
                return self.onKey?(key) ?? false
            }
            return swallowed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func fieldHasSelection(in window: NSWindow) -> Bool {
        guard let editor = window.firstResponder as? NSTextView else { return false }
        return editor.selectedRange().length > 0
    }
}
