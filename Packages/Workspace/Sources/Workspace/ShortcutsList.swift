//
//  ShortcutsList.swift
//  Workspace
//
//  Everything a person can do in Echo from the keyboard, as values, grouped
//  by where it works: what the keyboard shortcuts panel lists (⌘/, Help ›
//  Keyboard Shortcuts, or the palette's action). Not only Echo's own
//  shortcuts but the navigation, and what macOS gives every app that holds in
//  Echo too — its menus and how to reach them, text fields, dialogs, an open
//  menu, Tab and Space between controls when the system's keyboard
//  navigation is on — because the panel is the one place that answers "what
//  can I do without the mouse" (product owner, 2026-10-22). Keys are written
//  the way the rest of the window writes them: the palette's and Trash's
//  hints, `esc` as the palette's field has it, the menus' modifier glyphs.
//
//  Kept by hand beside the code that answers each key, which lives in many
//  places. Its tests hold it to what this package can read — the palette's
//  actions and its keyboard — and a hosted test holds it to every shortcut
//  in the app's menus. The global shortcut is the app target's, so it is
//  handed in rather than written twice.
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
                    ShortcutRow(label: "Record, or stop recording", keys: [globalShortcut]),
                    // macOS's own: focus moves to the menu bar's icons, Echo's
                    // among them, and ↵ opens its menu.
                    ShortcutRow(label: "Reach Echo's icon in the menu bar", keys: ["⌃F8"]),
                ]),
            ShortcutGroup(
                title: "The app",
                rows: [
                    ShortcutRow(label: "Settings", keys: ["⌘,"]),
                    ShortcutRow(label: "Keyboard shortcuts", keys: [toggleKeys]),
                    ShortcutRow(label: "Close the window", keys: ["⌘W"]),
                    ShortcutRow(label: "Minimize the window", keys: ["⌘M"]),
                    ShortcutRow(label: "Hide Echo", keys: ["⌘H"]),
                    ShortcutRow(label: "Hide the other apps", keys: ["⌥⌘H"]),
                    ShortcutRow(label: "Quit Echo", keys: ["⌘Q"]),
                    ShortcutRow(label: "Reach the menus", keys: ["⌃F2"]),
                    ShortcutRow(label: "Search the menus", keys: ["⇧⌘/"]),
                ]),
            ShortcutGroup(
                title: "In the window",
                rows: [
                    ShortcutRow(label: "Search", keys: ["⌘K"]),
                    ShortcutRow(label: "New recording", keys: ["⌘R"]),
                    ShortcutRow(label: "Previous or next meeting", keys: ["⌥⌘↑", "⌥⌘↓"]),
                    ShortcutRow(label: "Summary or Transcript", keys: ["⌘1", "⌘2"]),
                    ShortcutRow(label: "Next or previous control", keys: ["tab", "⇧tab"]),
                    ShortcutRow(label: "Press the control", keys: ["space"]),
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
                title: "In a meeting",
                rows: [
                    ShortcutRow(label: "Find in the transcript", keys: ["⌘F"]),
                    ShortcutRow(label: "Next match", keys: ["⌘G"]),
                    ShortcutRow(label: "Previous match", keys: ["⇧⌘G"]),
                    ShortcutRow(label: "Close find", keys: ["esc"]),
                    ShortcutRow(label: "Copy the selected words", keys: ["⌘C"]),
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
                title: "A row's actions",
                rows: [
                    ShortcutRow(label: "Move", keys: ["↑↓"]),
                    ShortcutRow(label: "Run", keys: ["↵"]),
                    ShortcutRow(label: "Close", keys: ["esc", "⌘K"]),
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
            ShortcutGroup(
                title: "In a text field",
                rows: [
                    ShortcutRow(label: "Undo", keys: ["⌘Z"]),
                    ShortcutRow(label: "Redo", keys: ["⇧⌘Z"]),
                    ShortcutRow(label: "Cut", keys: ["⌘X"]),
                    ShortcutRow(label: "Copy", keys: ["⌘C"]),
                    ShortcutRow(label: "Paste", keys: ["⌘V"]),
                    ShortcutRow(label: "Select all", keys: ["⌘A"]),
                    ShortcutRow(label: "Emoji and symbols", keys: ["fn E", "⌃⌘space"]),
                ]),
            ShortcutGroup(
                title: "In a dialog",
                rows: [
                    ShortcutRow(label: "The highlighted button", keys: ["↵"]),
                    ShortcutRow(label: "Cancel, or Later", keys: ["esc"]),
                ]),
            ShortcutGroup(
                title: "In a menu",
                rows: [
                    ShortcutRow(label: "Move", keys: ["↑↓"]),
                    ShortcutRow(label: "Into a submenu, or back", keys: ["→", "←"]),
                    ShortcutRow(label: "Choose", keys: ["↵"]),
                    ShortcutRow(label: "Close", keys: ["esc"]),
                ]),
        ]
    }
}
