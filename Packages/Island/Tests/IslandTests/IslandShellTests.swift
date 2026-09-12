//
//  IslandShellTests.swift
//  IslandTests
//
//  The shell: which face it wears for a given state, how big that makes it on
//  each of the two kinds of screen, and whether the flares actually bend the
//  way the design draws them.
//
//  The notched screen is the one spike #69 measured; the screen without a
//  cutout is a fixture and stays marked as one until #121 runs on hardware.
//

import CallDetection
import CoreGraphics
import DesignSystem
import Recording
import SwiftUI
import Testing

@testable import Island

@Suite("Island shell")
struct IslandShellTests {

    static let notched = IslandMetricsTests.macBookPro14
    static let noCutout = IslandMetricsTests.externalDisplay

    nonisolated static let meeting = UUID()

    // MARK: Which face

    @Test("nothing happening is the idle face")
    func idleWhenNothingHappens() {
        #expect(IslandShellFace.resolve(detection: nil, phase: .idle) == .idle)
    }

    @Test(
        "the session's own phases each reach the nearest face the design draws",
        arguments: [
            (RecordingPhase.recording(startedAt: Date(), scope: .everything), IslandShellFace.recording),
            (.stopping, .recording),
            (.finalizing(meetingID: meeting, progress: 0.4), .summarizing),
            (.summarizing(meetingID: meeting), .summarizing),
        ])
    func phaseChoosesAFace(phase: RecordingPhase, expected: IslandShellFace) {
        #expect(IslandShellFace.resolve(detection: nil, phase: phase) == expected)
    }

    @Test(
        "detection's faces outrank the session's: a question beats a report",
        arguments: [
            (IslandFace.startPrompt(appName: "Zoom", scoped: true), IslandShellFace.callDetected),
            (.compactPill, .callDetected),
            (.endGrace(appName: "Zoom"), .callEnded),
            (.saved, .saved),
        ])
    func detectionOutranksThePhase(detection: IslandFace, expected: IslandShellFace) {
        // Each of these is asked while a recording is running — the phase that
        // would otherwise answer `.recording`.
        let phase = RecordingPhase.recording(startedAt: Date(), scope: .everything)
        #expect(IslandShellFace.resolve(detection: detection, phase: phase) == expected)
    }

    @Test("a stop that is still saving keeps the recording face, never the saved one")
    func stoppingIsNotSaved() {
        // The asynchronous stop exists so that "saved" appears only once the
        // meeting is on disk. A silhouette that jumped ahead would say it a
        // second early, in the one place the user is looking.
        #expect(IslandShellFace.resolve(detection: nil, phase: .stopping) != .saved)
    }

    // MARK: Which state

    @Test(
        "the faces that need an answer open on their own",
        arguments: [IslandShellFace.callDetected, .callEnded, .saved])
    func askingFacesOpenThemselves(face: IslandShellFace) {
        #expect(face.expandsOnItsOwn(detection: nil))
    }

    @Test(
        "the faces that only report stay in the ears",
        arguments: [IslandShellFace.idle, .recording, .summarizing])
    func reportingFacesStayCollapsed(face: IslandShellFace) {
        #expect(!face.expandsOnItsOwn(detection: nil))
    }

    @Test("an offer that was ignored stays retracted")
    func theRetractedPromptStaysCollapsed() {
        // `compactPill` IS the retraction: the machine shrank an ignored offer
        // rather than nagging with it, and the shell must not undo that.
        #expect(!IslandShellFace.callDetected.expandsOnItsOwn(detection: .compactPill))
        #expect(
            IslandShellFace.callDetected.expandsOnItsOwn(
                detection: .startPrompt(appName: "Zoom", scoped: true)))
    }

    // MARK: The shell's size, on a notched screen

    @Test("a collapsed shell is the face's collapsed width and the cutout's own height")
    func collapsedOnANotchedScreen() {
        let geometry = IslandShellGeometry(metrics: .init(Self.notched), face: .recording, isExpanded: false)
        #expect(geometry.shellSize == CGSize(width: IslandWidth.recording.collapsed, height: 32))
        #expect(geometry.cornerRadius == EchoRadius.islandCollapsed)
    }

    @Test("every expanded face is one row tall; only the width moves")
    func expandedIsOneRowOnEveryFace() {
        let heights = Set(
            IslandShellFace.allCases.map {
                IslandShellGeometry(metrics: .init(Self.notched), face: $0, isExpanded: true).shellSize.height
            })
        #expect(heights == [EchoLayout.islandExpandedHeight])

        let widths = IslandShellFace.allCases.map {
            IslandShellGeometry(metrics: .init(Self.notched), face: $0, isExpanded: true).shellSize.width
        }
        #expect(Set(widths).count > 1, "the faces would all be one width, which is not what is drawn")
    }

    @Test("the window is wider than the shell by one flare at each end")
    func theWindowLeavesRoomForTheFlares() {
        let geometry = IslandShellGeometry(metrics: .init(Self.notched), face: .idle, isExpanded: true)
        #expect(geometry.flare == EchoLayout.islandFlare)
        #expect(geometry.panelSize.width == geometry.shellSize.width + 2 * EchoLayout.islandFlare)
        // Nothing above the shell: its top edge is flush with the screen's.
        #expect(geometry.panelSize.height == geometry.shellSize.height)
    }

    @Test("the collapsed shell knows the hole it has to split around; the expanded one has none")
    func onlyTheCollapsedShellSplitsAroundTheCutout() {
        let metrics = IslandMetrics(Self.notched)
        #expect(
            IslandShellGeometry(metrics: metrics, face: .recording, isExpanded: false).cutoutWidth
                == metrics.cutout?.width)
        #expect(IslandShellGeometry(metrics: metrics, face: .recording, isExpanded: true).cutoutWidth == nil)
    }

    @Test("a shell that hangs off the bezel casts nothing")
    func theNotchedShellHasNoShadow() {
        #expect(!IslandShellGeometry(metrics: .init(Self.notched), face: .idle, isExpanded: false).castsShadow)
    }

    @Test("the window hangs from the top of the screen, the shell's own top edge on it")
    func theNotchedWindowIsFlushWithTheScreen() {
        let metrics = IslandMetrics(Self.notched)
        let geometry = IslandShellGeometry(metrics: metrics, face: .recording, isExpanded: false)
        let frame = geometry.panelFrame(on: metrics)
        #expect(frame.maxY == metrics.screenFrame.maxY)
        #expect(frame.width == geometry.panelSize.width)
        // Centred on the cutout, which is not where the screen centres — to
        // within the rounding a window origin forces.
        #expect(abs(frame.midX - metrics.centerX) <= 0.5)
    }

    @Test("the window lands on whole points, because a window origin is whole points")
    func theWindowIsPlacedOnWholePoints() {
        // Measured on the 14" M4 Pro (2026-09-11): `NSWindow.setFrame` given
        // x −872.5 reports −873 back, on a 2x screen, before and after
        // ordering front. The cutout's centre IS a half point there, so the
        // rounding happens either way — this is it happening on purpose.
        let metrics = IslandMetrics(Self.notched)
        let geometry = IslandShellGeometry(metrics: metrics, face: .idle, isExpanded: false)
        let exact = metrics.frame(for: geometry.panelSize)
        #expect(exact.minX != exact.minX.rounded(), "the fixture stopped being the half-point case")

        let frame = geometry.panelFrame(on: metrics)
        #expect(frame.minX == frame.minX.rounded())
        #expect(frame.minY == frame.minY.rounded())
        // Downward, the direction the window was measured to take: rounding
        // the other way would be a second opinion for AppKit to overrule.
        #expect(frame.minX == exact.minX.rounded(.down))

        // And the shell still does not land where centring on the SCREEN
        // would have put it — which is the whole reason the cutout's centre is
        // derived rather than assumed.
        #expect(frame.midX != metrics.screenFrame.midX)
    }

    @Test("rounding never moves the shell more than half a point off the cutout")
    func roundingStaysOnTheCutout() {
        let metrics = IslandMetrics(Self.notched)
        for face in IslandShellFace.allCases {
            for isExpanded in [false, true] {
                let geometry = IslandShellGeometry(metrics: metrics, face: face, isExpanded: isExpanded)
                let drift = abs(geometry.panelFrame(on: metrics).midX - metrics.centerX)
                #expect(drift <= 0.5, "\(face) drifted \(drift) pt off the cutout's centre")
            }
        }
    }

    // MARK: The shell's size, on a screen with no cutout

    // UNVERIFIED (#121): no screen without a cutout has drawn this.

    @Test("the fallback is one fixed size collapsed, whatever face is on it")
    func theCollapsedPillIsOneSize() {
        let sizes = Set(
            IslandShellFace.allCases.map {
                IslandShellGeometry(metrics: .init(Self.noCutout), face: $0, isExpanded: false).shellSize
            })
        #expect(sizes == [EchoLayout.islandPillSize])
    }

    @Test("the fallback has no flares and casts instead")
    func thePillCastsRatherThanFlares() {
        let geometry = IslandShellGeometry(metrics: .init(Self.noCutout), face: .idle, isExpanded: false)
        #expect(geometry.flare == 0)
        #expect(geometry.cutoutWidth == nil)
        #expect(geometry.castsShadow)
        #expect(geometry.cornerRadius == EchoRadius.islandPill)
    }

    @Test("the fallback's window leaves room for the shadow on every side")
    func thePillsWindowHoldsItsShadow() {
        let geometry = IslandShellGeometry(metrics: .init(Self.noCutout), face: .idle, isExpanded: false)
        let reach = EchoLayout.islandPillShadowRadius + EchoLayout.islandPillShadowOffset
        #expect(geometry.panelSize.width == geometry.shellSize.width + 2 * reach)
        #expect(geometry.panelSize.height == geometry.shellSize.height + 2 * reach)
    }

    @Test("the fallback's own top edge sits below the menu bar, not the window's")
    func thePillHangsByItsShellAndNotByItsMargin() {
        // The window is taller than the pill by the room the shadow needs. If
        // the placement used the window's top edge the pill would hang a
        // shadow's reach lower than the design puts it.
        let metrics = IslandMetrics(Self.noCutout)
        let geometry = IslandShellGeometry(metrics: metrics, face: .idle, isExpanded: false)
        let frame = geometry.panelFrame(on: metrics)
        let shellTop = frame.maxY - geometry.shellInset.height
        #expect(shellTop == metrics.topEdge)
        #expect(shellTop < metrics.screenFrame.maxY, "the fallback floats below the menu bar")
    }

    // MARK: The outline

    static let shellRect = CGRect(x: 0, y: 0, width: 200, height: 32)
    static let flare = EchoLayout.islandFlare

    @Test("the flares stand outside the shell, one at each end")
    func theOutlineReachesBeyondTheShell() {
        let bounds = IslandShellShape(cornerRadius: EchoRadius.islandCollapsed)
            .path(in: Self.shellRect).boundingRect
        #expect(abs(bounds.minX - (Self.shellRect.minX - Self.flare)) < 0.5)
        #expect(abs(bounds.maxX - (Self.shellRect.maxX + Self.flare)) < 0.5)
        #expect(abs(bounds.height - Self.shellRect.height) < 0.5)
    }

    @Test("a flare is the corner's complement: filled against the shell, empty out at the bezel")
    func theFlaresBendAwayFromTheShell() {
        let path = IslandShellShape(cornerRadius: EchoRadius.islandCollapsed).path(in: Self.shellRect)
        // Just outside the shell's top corner, where the flare is thickest.
        #expect(path.contains(CGPoint(x: Self.shellRect.minX - 1, y: 1)))
        #expect(path.contains(CGPoint(x: Self.shellRect.maxX + 1, y: 1)))
        // Out at the far corner of the flare's own square, where a ROUNDED
        // corner would have put the ink and a concave one leaves none.
        #expect(!path.contains(CGPoint(x: Self.shellRect.minX - Self.flare + 1, y: Self.flare - 1)))
        #expect(!path.contains(CGPoint(x: Self.shellRect.maxX + Self.flare - 1, y: Self.flare - 1)))
    }

    @Test("the top corners are square and the bottom two are not")
    func onlyTheBottomCornersAreRounded() {
        let path = IslandShellShape(cornerRadius: EchoRadius.islandCollapsed).path(in: Self.shellRect)
        #expect(path.contains(CGPoint(x: Self.shellRect.minX + 0.5, y: 0.5)))
        #expect(path.contains(CGPoint(x: Self.shellRect.maxX - 0.5, y: 0.5)))
        #expect(!path.contains(CGPoint(x: Self.shellRect.minX + 0.5, y: Self.shellRect.maxY - 0.5)))
        #expect(!path.contains(CGPoint(x: Self.shellRect.maxX - 0.5, y: Self.shellRect.maxY - 0.5)))
    }

    @Test("a shell told to take no flare draws none")
    func noFlareIsAPlainTop() {
        let bounds = IslandShellShape(cornerRadius: EchoRadius.islandPill, flare: 0)
            .path(in: Self.shellRect).boundingRect
        #expect(abs(bounds.minX - Self.shellRect.minX) < 0.5)
        #expect(abs(bounds.maxX - Self.shellRect.maxX) < 0.5)
    }

    // MARK: For the eye

    @Test("the shell draws the same in both appearances")
    func theShellDoesNotFollowTheAppearance() throws {
        // The island is black on a light Mac too: it is poured from the bezel,
        // and a bezel does not go light.
        let metrics = IslandMetrics(Self.notched)
        for face in IslandShellFace.allCases {
            for isExpanded in [false, true] {
                let shell = IslandShell(
                    geometry: IslandShellGeometry(metrics: metrics, face: face, isExpanded: isExpanded),
                    isExpanded: isExpanded,
                    leadingEar: { Color.clear },
                    trailingEar: { Color.clear },
                    row: { Color.clear }
                )
                let light = try image(of: shell.environment(\.colorScheme, .light))
                let dark = try image(of: shell.environment(\.colorScheme, .dark))
                #expect(
                    light.dataProvider?.data == dark.dataProvider?.data,
                    "\(face) draws something that follows the appearance")
            }
        }
    }

    @Test("the gallery renders every face, on both kinds of screen")
    func theGalleryRenders() throws {
        EchoFont.registerBundledTypefaces()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-gallery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (screen, metrics) in [("notched", Self.notched), ("no-cutout", Self.noCutout)] {
            for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                let renderer = ImageRenderer(
                    content: IslandGallery(metrics: IslandMetrics(metrics))
                        .background(EchoColor.windowBackground)
                        .environment(\.colorScheme, scheme))
                renderer.scale = 2
                let cgImage = try #require(renderer.cgImage, "\(screen) rendered nothing in \(name)")
                #expect(cgImage.height > 1000, "the sheet is every face, not a slice of it")

                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("island-\(screen)-\(name).png"))
                Attachment.record(cgImage, named: "island-\(screen)-\(name).png")
            }
        }
    }

    private func image(of view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }
}
