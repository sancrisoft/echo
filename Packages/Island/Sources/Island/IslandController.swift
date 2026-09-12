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

    /// Whether the shell is open. In this layer only the faces that open on
    /// their own can set it; the pointer arrives with the hover layer.
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
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?

    /// The last recording state reported to detection. Kept so the news
    /// crosses once per change: `recordingChanged` can move detection's own
    /// face, which comes straight back here as an observation, and a report on
    /// every pass would chase its own tail.
    @ObservationIgnored private var reportedRecording: Bool?

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

        let panel = IslandPanel()
        panel.contentView = NSHostingView(
            rootView: IslandRootView(controller: self, detector: detector, session: session)
        )
        self.panel = panel

        // The screen the island belongs on can change without anything on the
        // island changing: a display is plugged in, the menu bar is hidden,
        // the resolution moves.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }

        observe()
        update()
    }

    /// Takes the island off screen and stops following anything. The panel is
    /// released with the controller; nothing here is meant to be restarted.
    public func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
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
        // Told first: detection's own face can change on this news, and the
        // face read below has to be the one after it, not before.
        reportRecording()

        let detection = detector.face
        face = IslandShellFace.resolve(detection: detection, phase: session.phase)
        isExpanded = face.expandsOnItsOwn(detection: detection)
        place()
    }

    private func reportRecording() {
        let isRecording = session.phase.isRecording
        guard reportedRecording != isRecording else { return }
        reportedRecording = isRecording
        detector.recordingChanged(isRecording)
    }

    // MARK: - Placement

    /// Sizes the window to the face and hangs it off the current screen.
    ///
    /// The screen is re-read on every placement rather than remembered: it is
    /// the one under the pointer, and the pointer moves. Between placements
    /// the island stays where it was put — following the pointer continuously
    /// would mean watching every mouse move system-wide, for a window that
    /// only needs to be right when it changes.
    private func place() {
        guard let panel else { return }
        guard let geometry = ScreenGeometry.underPointer() else {
            // No screens: nothing to hang off, and a window placed on a
            // screen that is not there is worse than no window.
            metrics = nil
            panel.orderOut(nil)
            return
        }
        let metrics = IslandMetrics(geometry)
        self.metrics = metrics
        panel.setFrame(
            IslandShellGeometry(metrics: metrics, face: face, isExpanded: isExpanded)
                .panelFrame(on: metrics),
            display: true
        )
        // Not `orderFront`: Echo is an accessory app, and the island appears
        // without activating it.
        panel.orderFrontRegardless()

        #if DEBUG
            // The island cannot be screenshotted without screen-recording
            // permission, and the screens it has never run on are an open
            // issue (#121). This is how a reading is taken from one: run the
            // app on that Mac and read the log.
            let reading =
                "\(metrics.shell)"
                + " frame \(NSStringFromRect(geometry.frame))"
                + " visible \(NSStringFromRect(geometry.visibleFrame))"
                + " safeAreaTop \(geometry.safeAreaTop)"
                + " statusBar \(geometry.statusBarThickness)"
                + " menuBar \(metrics.menuBarHeight)"
                + " scale \(panel.backingScaleFactor)"
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
