//
//  CallIslandPanel.swift
//  Echo
//
//  The notch island's window (ADR-018): a borderless, non-activating floating
//  panel at the top-center of the main screen, hosting `CallIslandView`.
//
//  Why a panel and not a notification: it never activates Echo or takes key
//  focus from the meeting app, it shows above fullscreen windows on every
//  Space, it can render a live countdown, and no Focus mode or screen-sharing
//  suppression can swallow it. Single instance, created on first show.
//
//  Dumb by construction: it owns frame and visibility only. Which face is on
//  screen is `CallDetectionController.face`, which the hosted SwiftUI view
//  observes directly.
//

import AppKit
import SwiftUI
import os

@MainActor
final class CallIslandPanelController {

    private var panel: NSPanel?

    func show(_ face: IslandFace, controller: CallDetectionController) {
        let panel = ensurePanel(controller: controller)
        place(panel)
        // Order front regardless of activation policy: Echo is usually an
        // `.accessory` agent, and the island must appear without activating it.
        panel.orderFrontRegardless()
        // Faces differ in size and SwiftUI lays the new one out on the next
        // tick, so place again then — otherwise the island would briefly wear
        // the frame of the face it just left.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel === panel else { return }
            self.place(panel)
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    #if DEBUG
    /// Dev-only: renders the island to PNG so its layout can be inspected from
    /// the CLI without screen-recording permission. Same two-path idiom as
    /// `DashboardView`'s ECHO_SNAPSHOT_PATH hook — `cacheDisplay` misses
    /// layer-only SwiftUI content on this OS, so the layer render (written to
    /// "…-layer.png") is the one that shows what is actually composited.
    func snapshot(to path: String) {
        guard let panel, let frameView = panel.contentView?.superview else { return }
        if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        guard let layer = frameView.layer else { return }
        let scale = panel.backingScaleFactor
        guard let ctx = CGContext(
            data: nil,
            width: Int(frameView.bounds.width * scale),
            height: Int(frameView.bounds.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let cg = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-layer.png")))
    }
    #endif

    // MARK: - Panel

    private func ensurePanel(controller: CallDetectionController) -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        // AFTER `isFloatingPanel`, which silently resets the level to
        // `.floating` (3). Setting the level first left the island below the
        // menu bar (24) and below Notification Center's full-screen window
        // (21): created, placed, ordered front — and invisible. Verified with
        // CGWindowListCopyWindowInfo, which is the only thing that shows the
        // real compositing order (a view-tree snapshot renders fine either way).
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false          // the SwiftUI view draws its own
        panel.becomesKeyOnlyIfNeeded = true
        // This controller holds the only reference; a stray close must not
        // release it out from under us.
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CallIslandView(controller: controller))

        self.panel = panel
        return panel
    }

    /// The screen the user is most likely looking at.
    ///
    /// `NSScreen.main` alone is not enough: it means "the screen with the key
    /// window", and Echo is an accessory app whose island never takes focus, so
    /// it resolves to the primary display. On a two-display setup that put the
    /// island on a screen the user wasn't using — a real call detected, an
    /// island shown, and nobody saw it (observed during SP-006 QA). The pointer
    /// is the better signal for "here".
    private static func targetScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Centers the island horizontally on that screen with its top edge tucked
    /// under the menu bar / notch area.
    private func place(_ panel: NSPanel) {
        guard let screen = Self.targetScreen(),
              let content = panel.contentView else { return }

        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        // "Tucked under the menu bar" needs a floor: with the menu bar set to
        // auto-hide, `visibleFrame` reserves nothing at the top, so the island
        // would sit inside the menu bar strip and fight it every time it
        // appears. Fall back to the status bar's own thickness in that case.
        let reserved = screen.frame.maxY - screen.visibleFrame.maxY
        let topInset = max(reserved, NSStatusBar.system.thickness)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - topInset - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        #if DEBUG
        MicActivityMonitor.log.info("Island placed at \(NSStringFromRect(frame), privacy: .public)")
        #endif
    }
}
