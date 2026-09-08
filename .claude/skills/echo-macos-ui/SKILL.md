---
name: echo-macos-ui
description: macOS platform traps Echo has already paid for — NavigationSplitView's rigid height, wallpaper-tinted window materials vs flat backgrounds, controls rendering inactive in an LSUIElement popover or panel, NSPanel level, List selection highlights and click gestures, waveform rendering, English-only strings, and how to verify UI without pixels or stealing focus.
---

Echo is `LSUIElement` (menu-bar agent), not sandboxed, deployment target 15.6, arm64. v2 is a rewrite so file names will move; the platform truths below do not. Current homes are named only as where the pattern lives today.

## Never activate the app to verify UI

Launch the debug build as often as needed, but it must **never take focus**: no `NSApp.activate(ignoringOtherApps:)`, no `makeKeyAndOrderFront`, no `open -a`. A synthetic-click probe that added `NSApp.activate` pulled the user out of what he was doing, twice. Launch with `ECHO_OPEN_DASHBOARD=1` + `ECHO_SNAPSHOT_PATH` only. **`ECHO_DUMP_ONESHOT=1` calls `NSApp.activate` itself** (`DashboardView.swift:183`) — do not use it while the user is at the machine.

## Pixel capture does not work here — read the trees

SwiftUI composites out of process: `cacheDisplay`, `layer.render` and `screencapture` all come back blank, the CLI lacks Screen Recording TCC, and SCK screenshot fails -3801. A blank body is also the expected result when the screen is locked or asleep (verified A/B against unmodified `main`), so it is environmental, not a regression. Verify from the DEBUG dump instead: `ECHO_APPEARANCE=dark|light` forces appearance and the snapshot hook writes `<snapshot>-views.txt` / `-layers.txt` with resolved background colors, materials and compositing filters.

**A view-tree snapshot cannot detect a compositing bug.** It produced perfect island faces while nothing was on screen. `CGWindowListCopyWindowInfo` (owner, layer, bounds, `kCGWindowIsOnscreen`) is the only tool that shows what a person actually sees, and it needs no permission. Reach for it whenever "it renders but nobody sees it".

## NavigationSplitView is unusable on this macOS

`NavigationSplitRepresentable` reports a rigid AppKit fitting height of roughly the screen (~1376-1428pt) **regardless of content**. In a smaller window SwiftUI centers the oversized canvas, so content overflows top and bottom: sidebar rows, headers and banners silently disappear and lists render under the toolbar. No SwiftUI knob fixes it — `.frame(min/ideal/max)`, `.defaultSize`, `.windowResizability` are all ignored because the rigidity lives in the representable's constraints. A `List` in that sidebar column also materializes **zero row views**, even plain `Text`.

Use a plain shell instead: `HStack(spacing: 0) { sidebar.frame(width: 240); Divider(); detail }` with custom sidebar rows (`DashboardView.swift:83-92`). `.toolbar` works fine without a split view, and `.defaultSize` is honored again afterwards.

## Do not paint flat opaque backgrounds next to Lists or chrome

On macOS 26 a `Window`'s base background is an `NSVisualEffectView` with material `.contentBackground`, composited as flat base + `CAChameleonLayer` wallpaper tint at opacity 0.10. The title bar, the sidebar, and `List` (now a native `ListCoreScrollView`, no `NSTableView`) each draw that same material themselves. An explicit `.background(Color(nsColor: .textBackgroundColor))` covers the tint, and in dark mode the flat region reads as a visibly mismatched band against the material around it. The window server composites the tint from the wallpaper, so **no flat color can ever match it**. Delete the background and let the material through (or `.scrollContentBackground(.hidden)` if a genuinely flat pane is wanted). The comment at `DashboardView.swift:93-98` guards this.

## Controls in the popover and the island render inactive — paint them yourself

Clicking the status item does not activate an `LSUIElement` app, so the `MenuBarExtra(.window)` popover is drawn while the app is **inactive**, and macOS strips the accent fill from standard controls there: an **on** `NSSwitch` gets the same grey track as **off**, leaving only knob position as a cue — a couple of points at `.controlSize(.mini)`. It was reported as "looks off but it's on" while the stored value was correct the whole time. **This is a rendering trap, not a state bug** — reaching for the binding wastes the debugging pass.

Any control in the popover or the never-key island gets an explicitly painted style, never a `.tint`ed system one: `PopoverSwitchStyle` (`MenuBarView.swift:432`) draws its own capsule; `IslandButtonStyle` (`CallIslandView.swift`) exists because `.borderedProminent` + `.tint` went invisible in the panel. Verify a style cheaply by rendering it through `ImageRenderer` in both `.aqua` and `.darkAqua` from a standalone `swiftc` file — no need to drive the real popover.

## NSPanel: set `level` after `isFloatingPanel`

`NSPanel.isFloatingPanel = true` **silently resets `level` to `.floating` (3)**. Assign `level` afterwards or the window sits below the system menu bar (24) and below Notification Center's full-screen window (21) — created, placed, ordered front, and invisible. `CallIslandPanel.swift:91-98` does it in that order (`[.borderless, .nonactivatingPanel]`, then `isFloatingPanel`, then `.statusBar`, plus `becomesKeyOnlyIfNeeded`).

With the menu bar set to auto-hide, `NSScreen.visibleFrame` reserves nothing at the top, so any top-edge layout needs an `NSStatusBar.system.thickness` floor (`CallIslandPanel.swift:143-144`).

## List selection: you cannot have both highlights

With a `selection:` binding, macOS 26 draws its own full-bleed accent bar (a nil-delegate `ContentLayer` spanning the row under `ListTableRowView`) and `.listRowBackground` does **not** suppress it — it draws on top. To get a custom card the binding must come off the `List` entirely, and selection, keyboard and right-click become yours. `.listRowBackground` also ignores `.listRowInsets`, so a card's gutter comes from the background view's own padding.

- `.simultaneousGesture(TapGesture(count: 2))` sits in front of the table's click handling and **swallows the first click** — the symptom was "the app looks frozen" with nothing ever highlighting.
- **Never put selection on a 1-count tap next to a 2-count tap.** SwiftUI waits out the system double-click interval (~0.5 s) to rule out a double, so the single-click handler fires half a second late and the highlight feels laggy. Selection rides `simultaneousGesture(DragGesture(minimumDistance: 0))`, which takes no part in tap-count disambiguation and reports on mouse-down — the same instant Finder moves its highlight. `onTapGesture(count: 2)` stays for open.
- Right-click-selects has no SwiftUI hook (`contextMenu` gives no "opening" callback, right-click is not a `TapGesture`). `RowRightClickWatcher` (`DashboardView.swift:1237`) uses `NSEvent.addLocalMonitorForEvents` for `.rightMouseDown`/control-click and returns the event untouched.

## Waveforms and copy

- Levels and waveforms must come from real capture. A `RecordingState` driven by a random simulator timer was rejected; if the real source is not wired, ask.
- When a slow source feeds a fast display, interpolate at the view (`GlidingLevel`, `WaveformView.swift:119`) — do not slow the display and do not fake data. Window level history by **duration**, never by callback count: the mic tap fires every ~100 ms and the system tap every ~12 ms, so a per-callback window silently covers 8x more audio on one channel.
- **All user-facing content is English** — labels, buttons, status text, `errorDescription` strings, and Info.plist TCC usage descriptions. Speaker labels are `"You"` / `"Others"`. Code comments may stay as they are.
