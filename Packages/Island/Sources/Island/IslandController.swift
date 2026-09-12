//
//  IslandController.swift
//  Island
//
//  The island's owner: it holds the panel, works out which face the shell is
//  wearing, sizes and places the window, and carries the one piece of news
//  that has to cross between the two packages under it.
//
//  The island is the only place detection and the session meet. `Recording`
//  sits above `CallDetection` and cannot observe it; `CallDetection` sits
//  below `Recording` and cannot observe that either — deliberately, so that
//  neither grows an opinion about the other. Whether a recording is running is
//  something detection's suppression rules genuinely need, so the object that
//  watches both tells it, once per change (`recordingChanged`).
//
//  It publishes what it decides — the face and whether the shell is open — and
//  does not hand its own collaborators out for a view to reach through: the
//  detector and the session are given to the view directly, and each observes
//  what it draws.
//

import AppKit
import CallDetection
import DesignSystem
import EchoCore
import Observation
import Recording
import SwiftUI
import os

@Observable
@MainActor
public final class IslandController {

    /// The face the shell is wearing.
    public private(set) var face: IslandShellFace = .idle

    /// Whether the shell is open: the pointer is on it, or the face is one of
    /// the three that open without one.
    public private(set) var isExpanded = false

    /// The screen the island is on, as it was read when it was last placed.
    /// `nil` before the first placement, and on a Mac reporting no screens at
    /// all — where there is nothing to draw on and the view draws nothing.
    public private(set) var metrics: IslandMetrics?

    @ObservationIgnored
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Island")

    @ObservationIgnored private let detector: CallDetector
    @ObservationIgnored private let session: RecordingSession
    @ObservationIgnored private var panel: IslandPanel?
    @ObservationIgnored private var screenObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var hover: HoverGrace?

    /// The display the island is currently on, so a placement can ask whether
    /// it is still attached. `nil` before the first one.
    @ObservationIgnored private var currentDisplay: CGDirectDisplayID?

    /// The pending re-placement after an activation, once `NSScreen.main` has
    /// caught up with it.
    @ObservationIgnored private var restage: Task<Void, Never>?

    /// The pending trim of a window that is larger than the shell inside it,
    /// because the shell is closing. Cancelled by anything that makes the
    /// window grow again, so a pointer that comes straight back never sees a
    /// window shrink under an opening shell.
    @ObservationIgnored private var settle: Task<Void, Never>?

    /// How long to let `NSScreen.main` settle after an app is activated.
    ///
    /// Measured on 2026-09-11 with two displays: at the instant
    /// `didActivateApplicationNotification` arrives, `NSScreen.main` still
    /// reports the screen being LEFT — every activation sampled, without
    /// exception — and had caught up 16–80 ms later. Reading it immediately
    /// would put the island on the screen the user just walked away from,
    /// which is the exact failure this whole layer exists to fix, so the read
    /// waits with margin over the slowest reading. The cost of waiting is a
    /// beat nobody is looking at yet; the cost of being early is the wrong
    /// screen.
    private static let activationSettle: Duration = .milliseconds(200)

    /// Whether the shell will actually move. The system's setting, read at the
    /// moment it matters rather than mirrored: the OS owns it, and the view
    /// reads the same setting through its own environment.
    private var animates: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The last recording state reported to detection. Kept so the news
    /// crosses once per change: `recordingChanged` can move detection's own
    /// face, which comes straight back here as an observation, and a report on
    /// every pass would chase its own tail.
    @ObservationIgnored private var reportedRecording: Bool?

    /// The last hover state reported to detection, on the same terms and for
    /// the same reason: telling it is what suspends the retract, and detection
    /// can answer by changing its face, which comes straight back here.
    @ObservationIgnored private var reportedHover: Bool?

    public init(detector: CallDetector, session: RecordingSession) {
        self.detector = detector
        self.session = session
    }

    /// Puts the island on screen and starts following what it shows.
    ///
    /// A launch side effect, so it is a call and not an initializer: nothing
    /// is created, placed or ordered front until the composition root says so
    /// (ADR-004).
    public func start() {
        guard panel == nil else { return }

        let hover = HoverGrace { [weak self] _ in self?.update() }
        self.hover = hover

        let tracking = IslandHoverView(
            hosting: NSHostingView(
                rootView: IslandRootView(controller: self, detector: detector, session: session)
            )
        )
        tracking.onCrossing = { entered in
            if entered { hover.entered() } else { hover.exited() }
        }

        let panel = IslandPanel()
        panel.contentView = tracking
        self.panel = panel

        followScreens()
        observe()
        update()
    }

    /// The screen the island belongs on changes without anything on the island
    /// changing, and it changes as an EVENT — which is the whole reason #194
    /// chose the active screen over the pointer. Two kinds of event cover it:
    ///
    ///   - the screens themselves are rearranged: a display plugged in or, the
    ///     case that matters, unplugged out from under the window;
    ///   - the user moves to another screen, which reaches an app that never
    ///     activates as somebody else being activated, or as the active Space
    ///     changing — with "Displays have separate Spaces" on, another
    ///     display's Space is another Space.
    ///
    /// The first is placed on at once: `NSScreen.screens` is already the new
    /// list when it arrives, and a window on a screen that is gone cannot wait.
    /// The second waits for `NSScreen.main` to catch up (`activationSettle`).
    private func followScreens() {
        let workspace = NSWorkspace.shared.notificationCenter
        screenObservers = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // A rearrangement outranks a pending activation: the list
                    // it would have read no longer exists.
                    self?.restage?.cancel()
                    self?.restage = nil
                    self?.place()
                }
            },
            workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeWhenActiveScreenSettles() }
            },
            workspace.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeWhenActiveScreenSettles() }
            },
        ]
    }

    /// Re-places once the active screen has settled. Coalesced, because
    /// activating an app raises both notifications and switching apps quickly
    /// raises several: the island is placed where the user ended up, not once
    /// per step of getting there.
    private func placeWhenActiveScreenSettles() {
        restage?.cancel()
        restage = Task { [weak self] in
            try? await Task.sleep(for: Self.activationSettle)
            guard !Task.isCancelled, let self, self.panel != nil else { return }
            self.restage = nil
            self.place()
        }
    }

    /// Takes the island off screen and stops following anything. The panel is
    /// released with the controller; nothing here is meant to be restarted.
    public func stop() {
        for observer in screenObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        screenObservers = []
        hover?.forget()
        hover = nil
        settle?.cancel()
        settle = nil
        restage?.cancel()
        restage = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Following what it shows

    /// Re-arms itself after every change, which is the same shape
    /// `CallDetector` uses to follow a setting: `withObservationTracking` is a
    /// single-shot, and the work has to happen after the value lands rather
    /// than inside the notification that it is about to.
    private func observe() {
        withObservationTracking {
            _ = detector.face
            _ = session.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.panel != nil else { return }
                self.observe()
                self.update()
            }
        }
    }

    /// Recomputes the face from both halves and puts the window where that
    /// face belongs.
    private func update() {
        // Told first, both of them: detection's own face can change on either
        // piece of news, and the face read below has to be the one after it,
        // not before.
        reportRecording()
        reportHover()

        let detection = detector.face
        face = IslandShellFace.resolve(detection: detection, phase: session.phase)
        isExpanded = face.isOpen(detection: detection, hovered: hover?.isInside ?? false)
        place()
    }

    private func reportRecording() {
        let isRecording = session.phase.isRecording
        guard reportedRecording != isRecording else { return }
        reportedRecording = isRecording
        detector.recordingChanged(isRecording)
    }

    /// Tells detection whether the pointer is on the island.
    ///
    /// The island is the only object that can answer this — detection sits
    /// below it and the spike measured that continuous pointer position is not
    /// available to the panel at all (#69) — and what it reports is the grace's
    /// answer, not the raw crossing. That is deliberate: a crossing is a
    /// mechanism, presence is the fact, and the retract must not restart
    /// because a window resized under a pointer that never moved.
    ///
    /// What it means is detection's: the timing is its own, it holds no
    /// opinion about the surface above, and the decision arrives as an event
    /// like every other.
    private func reportHover() {
        let isHovering = hover?.isInside ?? false
        guard reportedHover != isHovering else { return }
        reportedHover = isHovering
        detector.hoverChanged(isHovering)
    }

    // MARK: - Placement

    /// Sizes the window to the face and hangs it off the screen it belongs on.
    ///
    /// The screen is re-read on every placement rather than remembered — the
    /// active screen moves, and so does the set of screens there are — and the
    /// choice between staying and moving is `ScreenGeometry.choice`, which is
    /// where the three rules are written down.
    ///
    /// Placement happens whenever anything changes: a face, a hover, a
    /// recording, an app being activated, the screens being rearranged. The
    /// idle face is the one this matters most for, because it is the one that
    /// is on screen the rest of the time — measured on 2026-09-11, before this
    /// layer, it stayed behind on the display it was first placed on and there
    /// was nothing to hover where the user had gone (#194).
    private func place() {
        guard let panel else { return }
        guard
            let geometry = ScreenGeometry.forShell(
                current: currentDisplay,
                hovered: hover?.isInside ?? false
            )
        else {
            // No screens: nothing to hang off, and a window placed on a
            // screen that is not there is worse than no window.
            metrics = nil
            currentDisplay = nil
            panel.orderOut(nil)
            return
        }
        currentDisplay = geometry.displayID
        let metrics = IslandMetrics(geometry)
        self.metrics = metrics
        let target = IslandShellGeometry(metrics: metrics, face: face, isExpanded: isExpanded)
            .panelFrame(on: metrics)

        // The window has to hold the shell for the whole of the spring, and it
        // is not part of it: it takes the union now and is trimmed to the
        // target once the shell has stopped.
        settle?.cancel()
        settle = nil
        let animated = animates && panel.isVisible
        let now = IslandWindowTransition.now(from: panel.frame, to: target, animated: animated)
        panel.setFrame(now, display: true)
        if IslandWindowTransition.settles(now, to: target) {
            settle = Task { [weak self] in
                try? await Task.sleep(for: .seconds(EchoMotion.islandShellSpring.settlingDuration))
                guard !Task.isCancelled, let self, let panel = self.panel else { return }
                panel.setFrame(target, display: true)
                self.settle = nil
                #if DEBUG
                    Self.log.info(
                        "Island window trimmed to \(NSStringFromRect(target), privacy: .public)")
                #endif
            }
        }
        // Not `orderFront`: Echo is an accessory app, and the island appears
        // without activating it.
        panel.orderFrontRegardless()

        #if DEBUG
            // The island cannot be screenshotted without screen-recording
            // permission, and the screens it has never run on are an open
            // issue (#121). This is how a reading is taken from one: run the
            // app on that Mac and read the log.
            let reading =
                "\(face) \(isExpanded ? "open" : "shut")"
                + " display \(geometry.displayID) of \(NSScreen.screens.count)"
                + " hovered \(hover?.isInside ?? false)"
                + " pointer \(NSStringFromPoint(NSEvent.mouseLocation))"
                + " \(metrics.shell)"
                + " frame \(NSStringFromRect(geometry.frame))"
                + " visible \(NSStringFromRect(geometry.visibleFrame))"
                + " safeAreaTop \(geometry.safeAreaTop)"
                + " statusBar \(geometry.statusBarThickness)"
                + " menuBar \(metrics.menuBarHeight)"
                + " scale \(panel.backingScaleFactor)"
                + " shell \(NSStringFromRect(target))"
                + " window \(NSStringFromRect(panel.frame))"
            Self.log.info("Island placed: \(reading, privacy: .public)")
        #endif
    }

    #if DEBUG
        /// Renders the island to a PNG, the way the window renders itself.
        ///
        /// Pixels cannot be captured from outside a window on this macOS, and
        /// the island is a window nobody can point a screenshot at — so it
        /// draws itself instead. Two paths for one reason the PoC found the
        /// hard way: `cacheDisplay` misses layer-only SwiftUI content, and the
        /// layer render, written beside it, is the one that shows what is
        /// actually composited.
        public func snapshot(to path: URL) {
            guard let panel, let view = panel.contentView?.superview else {
                ErrorTrace.record("A snapshot was asked of an island that is not on screen", category: "Island")
                return
            }
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: path, options: .atomic)
                }
            }
            guard let layer = view.layer else { return }
            let scale = panel.backingScaleFactor
            guard
                let context = CGContext(
                    data: nil,
                    width: Int(view.bounds.width * scale),
                    height: Int(view.bounds.height * scale),
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                )
            else { return }
            context.scaleBy(x: scale, y: scale)
            layer.render(in: context)
            guard let image = context.makeImage() else { return }
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            try? png?.write(to: path.deletingPathExtension().appendingPathExtension("layer.png"), options: .atomic)
        }
    #endif
}
