//
//  ShortcutsList.swift
//  Workspace
//
//  Every key Echo answers to, as values, grouped by where it works: what the
//  keyboard shortcuts panel lists (⌘/, Help › Keyboard Shortcuts, or the
//  palette's action; product owner, 2026-10-22). Keys are written the way the
//  rest of the window writes them — the palette's and Trash's hints, `esc`
//  as the palette's field has it, the menus' modifier glyphs.
//
//  Kept by hand beside the code that answers each key, which lives in many
//  places; its tests hold it to the ones this package can read — the
//  palette's actions and its keyboard. The global shortcut is the app
//  target's, so it is handed in rather than written twice.
//

struct ShortcutRow: Equatable, Sendable {
    let label: String
    /// One keycap per key or combination; two mean either.
    let keys: [String]
}

struct ShortcutGroup: Equatable, Sendable, Identifiable {
    let title: String
    let rows: [ShortcutRow]

    var id: String { title }
}

enum ShortcutsList {

    /// The panel itself, bound by the app target's Help menu.
    static let toggleKeys = "⌘/"

    /// - Parameter globalShortcut: Record and Stop from anywhere, as the
    ///   menus write it.
    static func groups(globalShortcut: String) -> [ShortcutGroup] {
        [
            ShortcutGroup(
                title: "Anywhere",
                rows: [
                    ShortcutRow(label: "Record, or stop recording", keys: [globalShortcut])
                ]),
            ShortcutGroup(
                title: "In the window",
                rows: [
                    ShortcutRow(label: "Search", keys: ["⌘K"]),
                    ShortcutRow(label: "New recording", keys: ["⌘R"]),
                    ShortcutRow(label: "Settings", keys: ["⌘,"]),
                    ShortcutRow(label: "Keyboard shortcuts", keys: [toggleKeys]),
                ]),
            ShortcutGroup(
                title: "Meetings",
                rows: [
                    ShortcutRow(label: "Move", keys: ["↑↓"]),
                    ShortcutRow(label: "First or last", keys: ["home", "end"]),
                    ShortcutRow(label: "Show the meeting", keys: ["↵"]),
                    ShortcutRow(label: "Move to Trash", keys: ["⌫"]),
                ]),
            ShortcutGroup(
                title: "In a transcript",
                rows: [
                    ShortcutRow(label: "Find", keys: ["⌘F"]),
                    ShortcutRow(label: "Next match", keys: ["⌘G"]),
                    ShortcutRow(label: "Previous match", keys: ["⇧⌘G"]),
                    ShortcutRow(label: "Close find", keys: ["esc"]),
                ]),
            ShortcutGroup(
                title: "In search",
                rows: [
                    ShortcutRow(label: "Move", keys: ["↑↓"]),
                    ShortcutRow(label: "Open", keys: ["↵"]),
                    ShortcutRow(label: "Open on the other tab", keys: ["⌘↵"]),
                    ShortcutRow(label: "Change what it reads", keys: ["tab", "⇧tab"]),
                    ShortcutRow(label: "Open one of the first nine", keys: ["⌘1–9"]),
                    ShortcutRow(label: "Copy the summary", keys: ["⌘C"]),
                    ShortcutRow(label: "A row's actions", keys: ["⌘K"]),
                    ShortcutRow(label: "Close", keys: ["esc"]),
                ]),
            ShortcutGroup(
                title: "Trash",
                rows: [
                    ShortcutRow(label: "Move", keys: ["↑↓"]),
                    ShortcutRow(label: "First or last", keys: ["home", "end"]),
                    ShortcutRow(label: "Open", keys: ["↵"]),
                    ShortcutRow(label: "Ask before deleting for good", keys: ["⌫"]),
                    ShortcutRow(label: "Back to Trash", keys: ["esc"]),
                ]),
        ]
    }
}
