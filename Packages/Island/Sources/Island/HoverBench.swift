//
//  HoverBench.swift
//  Island
//
//  The bench for the one question the island's whole interaction rests on:
//  does a borderless, non-activating panel at `.statusBar` level actually
//  receive hover, and never take focus while doing it?
//
//  Kept for the same reason `FixtureRecorder` is kept. Nothing Apple documents
//  guarantees the answer, the answer decides the island's shape, and finding it
//  again from scratch costs a day. It arms exactly one mechanism per run so the
//  report says which of the two answered, rather than leaving both live and
//  crediting the wrong one.
//
//  Run it from a harness that owns an `NSApplication` — the panel needs a live
//  run loop, and the bench yields to it between moves:
//
//      let app = NSApplication.shared
//      app.setActivationPolicy(.accessory)   // never steal focus
//      final class D: NSObject, NSApplicationDelegate {
//          func applicationDidFinishLaunching(_ n: Notification) {
//              Task { @MainActor in
//                  print(await HoverBench(mechanism: .trackingArea).run())
//                  print(await HoverBench(mechanism: .acceptsMouseMovedEvents).run())
//                  NSApp.terminate(nil)
//              }
//          }
//      }
//      let d = D(); app.delegate = d; app.run()
//
//  It drives the pointer with `CGWarpMouseCursorPosition` and puts it back
//  where it found it. A locked screen makes every count zero — `loginwindow`
//  owns the event stream — so check `CGSessionCopyCurrentDictionary()` for
//  `CGSSessionScreenIsLocked` before believing a negative result. This bit,
//  twice: a run that locked halfway reported four honest-looking zeroes.
//
//  What it measured on 2026-09-11, 14" MacBook Pro M4 Pro (Mac16,8), across
//  enter, exit, a five-times-repeated fast pass and another app frontmost:
//
//    .trackingArea               14 entered / 14 exited over two runs, always
//                                paired, every condition. This is the one that
//                                works, and the only one the island may rely on.
//    .acceptsMouseMovedEvents    0 events of any kind, all four conditions, on
//                                a clean unlocked run. Setting the flag does
//                                not rescue a window that never becomes key.
//    mouseMoved                  unreliable either way: 8 events in one of
//                                eight condition-runs and 0 in the other seven,
//                                even with `.mouseMoved` in the tracking area's
//                                options. Treat continuous pointer position as
//                                unavailable here; hover is crossings only.
//
//  `isKeyWindow` and `NSApp.isActive` were false at the end of every run.
//

import AppKit
import CoreGraphics

#if DEBUG
    /// Drives the pointer across a real panel and counts what arrives.
    public final class HoverBench {

        /// The two ways a window that never becomes key can learn about the
        /// pointer. Exactly one is armed per run.
        public enum Mechanism: String, Sendable {
            /// An `NSTrackingArea` with `.activeAlways`, which reports the
            /// crossings themselves: `mouseEntered` and `mouseExited`.
            case trackingArea
            /// `NSWindow.acceptsMouseMovedEvents`, which reports a stream of
            /// `mouseMoved` and leaves the crossings to be derived from it.
            case acceptsMouseMovedEvents
        }

        /// What one condition produced.
        public struct Observation: Sendable {
            public let name: String
            public var entered = 0
            public var exited = 0
            public var moved = 0
            public var frontmost = ""
        }

        public struct Report: Sendable, CustomStringConvertible {
            public let mechanism: Mechanism
            public var observations: [Observation] = []
            /// The claim that matters as much as hover: the panel must never
            /// take key, and the app must never activate.
            public var everBecameKey = false
            public var everActivated = false

            public var description: String {
                var out = "HoverBench(\(mechanism.rawValue))\n"
                for o in observations {
                    out += String(
                        format: "  %-24s entered %d  exited %d  moved %-4d  frontmost %@\n",
                        (o.name as NSString).utf8String ?? "", o.entered, o.exited, o.moved, o.frontmost
                    )
                }
                out += "  focus: everBecameKey \(everBecameKey), everActivated \(everActivated)"
                return out
            }
        }

        private let mechanism: Mechanism
        private let panel: NSPanel
        private let probe: ProbeView
        private var current = Observation(name: "")

        public init(mechanism: Mechanism) {
            self.mechanism = mechanism
            probe = ProbeView(installTrackingArea: mechanism == .trackingArea)
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 32),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isFloatingPanel = true
            // AFTER `isFloatingPanel`, which silently resets the level to
            // `.floating` (3) — below the menu bar (24). Set first, the panel
            // is created, placed, ordered front and invisible.
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.isMovable = false
            panel.backgroundColor = .black
            panel.isOpaque = false
            panel.hasShadow = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = mechanism == .acceptsMouseMovedEvents
            panel.contentView = probe
        }

        /// Drives the pointer through every condition and reports the counts.
        public func run() async -> Report {
            var report = Report(mechanism: mechanism)
            probe.onEntered = { [weak self] in self?.current.entered += 1 }
            probe.onExited = { [weak self] in self?.current.exited += 1 }
            probe.onMoved = { [weak self] in self?.current.moved += 1 }

            guard let geometry = ScreenGeometry.underPointer() else { return report }
            let metrics = IslandMetrics(geometry)
            let frame = metrics.frame(for: CGSize(width: 320, height: metrics.collapsedHeight))
            panel.setFrame(frame, display: true)
            // Not `orderFront`: Echo is an accessory app, and the island has to
            // appear without activating it.
            panel.orderFrontRegardless()

            let origin = NSEvent.mouseLocation
            let below = frame.minY - 220
            // Inside the shell but clear of the cutout, so the pointer is over
            // a lit pixel rather than behind the bezel.
            let earX = frame.midX - 120

            report.observations.append(
                await observe("enter") {
                    await self.glide(from: CGPoint(x: earX, y: below), to: CGPoint(x: earX, y: frame.midY), steps: 24)
                })
            report.observations.append(
                await observe("exit") {
                    await self.glide(from: CGPoint(x: earX, y: frame.midY), to: CGPoint(x: earX, y: below), steps: 24)
                })
            report.observations.append(
                await observe("fast pass") {
                    for _ in 0..<5 {
                        // Three samples across the whole shell: the crossing a
                        // hurried pointer actually makes.
                        self.warp(CGPoint(x: frame.minX - 180, y: frame.midY))
                        self.warp(CGPoint(x: frame.midX, y: frame.midY))
                        self.warp(CGPoint(x: frame.maxX + 180, y: frame.midY))
                        try? await Task.sleep(for: .milliseconds(260))
                        self.warp(CGPoint(x: frame.maxX + 180, y: below))
                        try? await Task.sleep(for: .milliseconds(160))
                    }
                })

            // The condition with no record behind it: hover while a different
            // app owns the front.
            if let finder = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.apple.finder"
            }) {
                finder.activate()
                try? await Task.sleep(for: .milliseconds(900))
            }
            report.observations.append(
                await observe("other app frontmost") {
                    await self.glide(from: CGPoint(x: earX, y: below), to: CGPoint(x: earX, y: frame.midY), steps: 24)
                    await self.glide(from: CGPoint(x: earX, y: frame.midY), to: CGPoint(x: earX, y: below), steps: 24)
                })

            report.everBecameKey = panel.isKeyWindow
            report.everActivated = NSApp.isActive
            warp(origin)
            panel.orderOut(nil)
            return report
        }

        private func observe(_ name: String, _ body: () async -> Void) async -> Observation {
            current = Observation(name: name)
            await body()
            try? await Task.sleep(for: .milliseconds(300))
            current.frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            return current
        }

        /// `CGWarpMouseCursorPosition` takes top-left global coordinates; every
        /// frame here is AppKit's bottom-left.
        private func warp(_ appKitPoint: CGPoint) {
            guard let primary = NSScreen.screens.first else { return }
            CGWarpMouseCursorPosition(CGPoint(x: appKitPoint.x, y: primary.frame.maxY - appKitPoint.y))
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        private func glide(from: CGPoint, to: CGPoint, steps: Int) async {
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                warp(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                // Yields to the run loop, which is what lets the panel process
                // the events this move just produced.
                try? await Task.sleep(for: .milliseconds(16))
            }
        }

        /// Counts crossings when a tracking area is installed, and moves when
        /// the window accepts them. Whichever is armed, the other stays silent.
        private final class ProbeView: NSView {
            var onEntered: () -> Void = {}
            var onExited: () -> Void = {}
            var onMoved: () -> Void = {}
            private let installTrackingArea: Bool

            init(installTrackingArea: Bool) {
                self.installTrackingArea = installTrackingArea
                super.init(frame: .zero)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { nil }

            override func updateTrackingAreas() {
                super.updateTrackingAreas()
                for area in trackingAreas { removeTrackingArea(area) }
                guard installTrackingArea else { return }
                addTrackingArea(
                    NSTrackingArea(
                        rect: .zero,
                        options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                        owner: self,
                        userInfo: nil
                    ))
            }

            override func mouseEntered(with event: NSEvent) { onEntered() }
            override func mouseExited(with event: NSEvent) { onExited() }
            override func mouseMoved(with event: NSEvent) { onMoved() }
        }
    }
#endif
