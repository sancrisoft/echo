//
//  MenuBarItem.swift
//  Echo
//
//  The menu bar item, managed by hand rather than by `MenuBarExtra`, which
//  opens its menu on any click and cannot tell the two mouse buttons apart.
//  Here they do different things: the left button opens the dashboard, and the
//  right one — Control-click included, which macOS treats as the same gesture —
//  opens the flat menu. The item is the only part of Echo a new user finds
//  unaided, so it leads to the app rather than to a list of things about it.
//
//  What it shows is the mark: a template image while nothing is recording, so
//  the bar inverts it with everything else, and the mark in the recording red
//  with the elapsed time beside it while a session runs. That second state is
//  not a template — a template cannot be red — and it is the one thing on the
//  bar a meeting in progress has to be visible as.
//
//  With the island switched off, the item says what the collapsed island
//  would have said in its ears, in full: the call's app, the clock, the
//  countdown to the stop in red, "Saved", the work after a stop (DEC-1,
//  product owner 2026-10-02). The island's ears shorten some of those to fit
//  beside a real cutout; the bar has the room.
//
//  It is also the one view an agent app always has on screen, so it carries the
//  bridge that hands SwiftUI's `openWindow` to the AppKit side. Without that,
//  the app menu, the menu's own Open Echo and a reopen all lose the only way
//  they have to put a window up.
//

import AppKit
import DesignSystem
import Island
import Recording
import SwiftUI

final class MenuBarItem: NSObject, NSMenuDelegate {

    private let contents: MenuBarMenu
    private let windowOpener: WindowOpener
    private let phase: () -> RecordingPhase
    private let ears: () -> IslandEars
    private let showsIsland: () -> Bool
    private var item: NSStatusItem?

    /// The clock or the countdown while one runs. It ticks on the session's
    /// own seconds — or the deadline's — not on whenever it happened to start,
    /// so the bar and the island turn over together.
    private var ticker: Task<Void, Never>?
    private var tickingFrom: Date?

    /// The last whole seconds the clock read, kept for the moment the session
    /// stops and the island's ears hold the clock where it stopped.
    private var lastElapsed = 0

    /// The open menu, while it is open: its clock and countdown move on.
    private var openMenu: NSMenu?
    private var menuTicker: Task<Void, Never>?

    /// - Parameters:
    ///   - phase: asked whenever the item draws and followed for changes,
    ///     never held: what the bar shows is the session's phase now.
    ///   - ears: what the collapsed island would say, for when it is off.
    ///   - showsIsland: whether the island is switched on, read at each draw.
    init(
        contents: MenuBarMenu,
        windowOpener: WindowOpener,
        phase: @escaping () -> RecordingPhase,
        ears: @escaping () -> IslandEars,
        showsIsland: @escaping () -> Bool
    ) {
        self.contents = contents
        self.windowOpener = windowOpener
        self.phase = phase
        self.ears = ears
        self.showsIsland = showsIsland
    }

    /// Puts the item in the menu bar. Called once the app is actually up: a
    /// status item needs a live `NSApplication`, and `AppComposition.start()`
    /// runs before SwiftUI has created one.
    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(clicked)
            // Both buttons have to reach the action for it to be able to tell
            // them apart; a status item reports only the left one by default.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.addSubview(bridge())
        }
        self.item = item
        follow()
    }

    /// The zero-size SwiftUI view that captures `openWindow`. It hitches a ride
    /// on the button because that is the view this app always has, and it
    /// answers no clicks of its own.
    private func bridge() -> NSView {
        let bridge = NSHostingView(
            rootView: WindowOpenerBridge(opener: windowOpener).allowsHitTesting(false)
        )
        bridge.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        return bridge
    }

    // MARK: - What it shows

    /// What the item shows.
    enum Look: Equatable {
        /// The mark, as a template.
        case idle
        /// The mark in red and the whole seconds since the session began.
        case recording(elapsed: Int)
        /// The mark in red and the countdown to the stop, in the clock's face.
        case countdown(String)
        /// The mark and the name of a call's app, in the bar's own ink.
        case call(String)
        /// The mark and a word of status, in the bar's own ink.
        case status(String)

        /// With the island up: only a live capture is shown. Stopping, the
        /// transcription pass and the summary are work the user did not ask
        /// to watch from the bar; the island reports them.
        static func of(_ phase: RecordingPhase, now: Date) -> Look {
            guard let startedAt = phase.startedAt else { return .idle }
            return .recording(elapsed: EchoClock.elapsedSeconds(since: startedAt, now: now))
        }

        /// With the island switched off: what its ears would say. A clock
        /// that has stopped holds `stoppedAt`, as the ears do.
        static func of(_ ears: IslandEars, now: Date, stoppedAt: Int) -> Look {
            switch ears {
            case .none: return .idle
            case .clock(let startedAt):
                return .recording(
                    elapsed: startedAt.map { EchoClock.elapsedSeconds(since: $0, now: now) } ?? stoppedAt)
            case .countdown:
                return ears.text(now: now).map(Look.countdown) ?? .idle
            case .call:
                return ears.text(now: now).map(Look.call) ?? .idle
            case .saved, .afterStop:
                return ears.text(now: now).map(Look.status) ?? .idle
            }
        }
    }

    /// Re-arms after every change, the shape `IslandController` and
    /// `CallDetector` follow their own sources with: `withObservationTracking`
    /// fires once, and the work belongs after the value lands.
    private func follow() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func render() {
        guard let button = item?.button else { return }
        let now = Date.now
        let look: Look
        let reference: Date?
        if showsIsland() {
            let current = phase()
            look = Look.of(current, now: now)
            reference = current.startedAt
        } else {
            let said = ears()
            look = Look.of(said, now: now, stoppedAt: lastElapsed)
            switch said {
            case .clock(let startedAt): reference = startedAt
            case .countdown(let deadline): reference = deadline
            case .none, .call, .saved, .afterStop: reference = nil
            }
        }
        if case .recording(let elapsed) = look { lastElapsed = elapsed }
        button.image = Self.image(for: look)
        tick(from: reference)
    }

    /// Redraws at each whole second of `reference` — the session's start, or
    /// the countdown's deadline — while there is one. The wait is worked out
    /// again every time rather than a fixed second, so a late wake-up does not
    /// carry into the next one.
    private func tick(from reference: Date?) {
        guard reference != tickingFrom else { return }
        ticker?.cancel()
        tickingFrom = reference
        guard let reference else {
            ticker = nil
            return
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                let into = Date.now.timeIntervalSince(reference).truncatingRemainder(dividingBy: 1)
                let wait = into >= 0 ? 1 - into : -into
                try? await Task.sleep(for: .seconds(max(0.05, wait)))
                guard !Task.isCancelled else { return }
                self?.render()
            }
        }
    }

    private static let idleImage = EchoMarkImage.make(size: EchoControl.menuBarMarkSize, isTemplate: true)

    private static func image(for look: Look) -> NSImage {
        switch look {
        case .idle:
            return idleImage
        case .recording(let elapsed):
            let clock = EchoClock.compact(elapsed)
            return markAndWords(
                clock, font: EchoFont.nsMono(EchoControl.menuBarTimerSize), ink: NSColor(EchoColor.recording),
                description: "Echo, recording, \(clock)")
        case .countdown(let words):
            return markAndWords(
                words, font: EchoFont.nsMono(EchoControl.menuBarTimerSize), ink: NSColor(EchoColor.recording),
                description: "Echo, \(words)")
        case .call(let app):
            return markAndWords(
                app, font: EchoFont.nsInterface(EchoControl.menuBarTimerSize, weight: EchoFont.earNameWeight),
                ink: nil, description: "Echo, \(app)")
        case .status(let words):
            return markAndWords(
                words, font: EchoFont.nsInterface(EchoControl.menuBarTimerSize, weight: EchoFont.earStatusWeight),
                ink: nil, description: "Echo, \(words)")
        }
    }

    /// The mark and its words as one image, so the gap between them is the
    /// design's rather than whatever a button puts between an image and a
    /// title. `ink` nil draws a template, which the bar inks with everything
    /// else on it; a template cannot be red, so red is drawn in.
    ///
    /// `nonisolated`, so the drawing handler it builds is too: AppKit decides
    /// which thread draws an image, and a handler bound to the main actor would
    /// trap on any other.
    private nonisolated static func markAndWords(
        _ words: String, font: NSFont, ink: NSColor?, description: String
    ) -> NSImage {
        let color = ink ?? .black
        let markSize = EchoControl.menuBarMarkSize
        let gap = EchoControl.menuBarTimerGap
        let measured = (words as NSString).size(withAttributes: [.font: font])
        let size = NSSize(
            width: markSize + gap + measured.width.rounded(.up),
            height: max(markSize, measured.height.rounded(.up))
        )
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            EchoMarkImage.draw(
                in: CGRect(x: 0, y: (rect.height - markSize) / 2, width: markSize, height: markSize),
                context: context,
                ink: color
            )
            (words as NSString).draw(
                at: NSPoint(x: markSize + gap, y: (rect.height - measured.height) / 2),
                withAttributes: [.font: font, .foregroundColor: color]
            )
            return true
        }
        image.isTemplate = ink == nil
        image.accessibilityDescription = description
        return image
    }

    // MARK: - Clicks

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else {
            // Nothing to read the gesture from. The dashboard is the answer to
            // the click this is most likely to be.
            windowOpener.openMainWindow()
            return
        }
        if Self.opensMenu(for: event.type, modifiers: event.modifierFlags) {
            showMenu()
        } else {
            windowOpener.openMainWindow()
        }
    }

    /// The right button opens the menu. So does Control-click: macOS treats it
    /// as the same gesture, and it arrives as a left click carrying `.control`.
    nonisolated static func opensMenu(for type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Bool {
        if type == .rightMouseUp || type == .rightMouseDown { return true }
        return modifiers.contains(.control)
    }

    /// The menu is attached only while it is open. A status item with a menu
    /// set swallows the click itself, and the left button would never reach the
    /// action again.
    private func showMenu() {
        guard let item, let button = item.button else { return }
        let menu = contents.build()
        menu.delegate = self
        item.menu = menu
        button.performClick(nil)
    }

    /// An open menu is brought up to date once a second, so a clock or a
    /// countdown in it is never a reading from when it was opened — the
    /// countdown is the one that matters, because it ends in a stop.
    func menuWillOpen(_ menu: NSMenu) {
        openMenu = menu
        menuTicker?.cancel()
        menuTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let menu = self.openMenu else { return }
                self.contents.refresh(menu)
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTicker?.cancel()
        menuTicker = nil
        openMenu = nil
        menu.delegate = nil
        item?.menu = nil
    }
}
