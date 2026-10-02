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
//  It is also the one view an agent app always has on screen, so it carries the
//  bridge that hands SwiftUI's `openWindow` to the AppKit side. Without that,
//  the app menu, the menu's own Open Echo and a reopen all lose the only way
//  they have to put a window up.
//

import AppKit
import DesignSystem
import Recording
import SwiftUI

final class MenuBarItem: NSObject, NSMenuDelegate {

    private let contents: MenuBarMenu
    private let windowOpener: WindowOpener
    private let phase: () -> RecordingPhase
    private var item: NSStatusItem?

    /// The clock while a session runs. It ticks on the session's own seconds,
    /// not on whenever it happened to start, so the bar and the island turn
    /// over together.
    private var ticker: Task<Void, Never>?

    /// - Parameter phase: asked whenever the item draws and followed for
    ///   changes, never held: what the bar shows is the session's phase now.
    init(contents: MenuBarMenu, windowOpener: WindowOpener, phase: @escaping () -> RecordingPhase) {
        self.contents = contents
        self.windowOpener = windowOpener
        self.phase = phase
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

    /// What the item shows, decided from the phase alone.
    enum Look: Equatable {
        /// The mark, as a template.
        case idle
        /// The mark in red and the whole seconds since the session began.
        case recording(elapsed: Int)

        /// Only a live capture is shown. Stopping, the transcription pass and
        /// the summary are work the user did not ask to watch from the bar;
        /// the island reports them.
        static func of(_ phase: RecordingPhase, now: Date) -> Look {
            guard let startedAt = phase.startedAt else { return .idle }
            return .recording(elapsed: EchoClock.elapsedSeconds(since: startedAt, now: now))
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
        let current = phase()
        switch Look.of(current, now: .now) {
        case .idle:
            ticker?.cancel()
            ticker = nil
            button.image = Self.idleImage
        case .recording(let elapsed):
            button.image = Self.recordingImage(clock: EchoClock.compact(elapsed))
            if ticker == nil, let startedAt = current.startedAt {
                ticker = tick(from: startedAt)
            }
        }
    }

    /// Redraws at each whole second of the session. The wait is worked out
    /// again every time rather than a fixed second, so a late wake-up does not
    /// carry into the next one.
    private func tick(from startedAt: Date) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                let into = Date.now.timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 1)
                try? await Task.sleep(for: .seconds(max(0.05, 1 - into)))
                guard !Task.isCancelled else { return }
                self?.render()
            }
        }
    }

    private static let idleImage = EchoMarkImage.make(size: EchoControl.menuBarMarkSize, isTemplate: true)

    /// The red mark and the clock as one image, so the gap between them is the
    /// design's rather than whatever a button puts between an image and a
    /// title. `nonisolated`, so the drawing handler it builds is too: AppKit
    /// decides which thread draws an image, and a handler bound to the main
    /// actor would trap on any other.
    private nonisolated static func recordingImage(clock: String) -> NSImage {
        let ink = NSColor(EchoColor.recording)
        let font = EchoFont.nsMono(EchoControl.menuBarTimerSize)
        let markSize = EchoControl.menuBarMarkSize
        let gap = EchoControl.menuBarTimerGap
        let measured = (clock as NSString).size(withAttributes: [.font: font])
        let size = NSSize(
            width: markSize + gap + measured.width.rounded(.up),
            height: max(markSize, measured.height.rounded(.up))
        )
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            EchoMarkImage.draw(
                in: CGRect(x: 0, y: (rect.height - markSize) / 2, width: markSize, height: markSize),
                context: context,
                ink: ink
            )
            (clock as NSString).draw(
                at: NSPoint(x: markSize + gap, y: (rect.height - measured.height) / 2),
                withAttributes: [.font: font, .foregroundColor: ink]
            )
            return true
        }
        image.accessibilityDescription = "Echo, recording, \(clock)"
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

    func menuDidClose(_ menu: NSMenu) {
        menu.delegate = nil
        item?.menu = nil
    }
}
