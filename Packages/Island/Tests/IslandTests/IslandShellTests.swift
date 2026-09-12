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

    @Test(
        "the pointer opens any face",
        arguments: IslandShellFace.allCases)
    func hoverOpensEveryFace(face: IslandShellFace) {
        #expect(face.isOpen(detection: nil, hovered: true))
    }

    @Test("the pointer cannot shut a face that opened on its own")
    func hoverNeverCloses() {
        // It is the pointer's absence, and a face that raised itself did not
        // raise itself to be dismissed by one.
        for face in IslandShellFace.allCases where face.expandsOnItsOwn(detection: nil) {
            #expect(face.isOpen(detection: nil, hovered: false))
        }
    }

    @Test("the reporting faces are shut with no pointer on them")
    func withoutThePointerTheQuietFacesAreShut() {
        for face in [IslandShellFace.idle, .recording, .summarizing] {
            #expect(!face.isOpen(detection: nil, hovered: false))
        }
    }

    // MARK: Whether there is a shell at all

    @Test(
        "a screen with a cutout always has the island on it",
        arguments: IslandShellFace.allCases)
    func theNotchedScreenKeepsTheIsland(face: IslandShellFace) {
        // It hides in the hole, so it costs nothing to leave there — and the
        // idle face being reachable IS how a recording starts from the island.
        for hovered in [true, false] {
            #expect(face.isOnScreen(hasCutout: true, hovered: hovered), "\(face)")
        }
    }

    @Test("a session's whole life, on a screen with no cutout")
    func theBareScreenFollowsTheNews() {
        // The reported behaviour, as a sequence: nothing on screen until
        // something happens, then something on screen for as long as it is
        // happening, then nothing again.
        let steps: [(detection: IslandFace?, phase: RecordingPhase, onScreen: Bool)] = [
            (nil, .idle, false),
            (.startPrompt(appName: "Zoom", scoped: true), .idle, true),
            (.compactPill, .idle, true),
            (nil, .recording(startedAt: Date(), scope: .everything), true),
            (nil, .stopping, true),
            (nil, .finalizing(meetingID: Self.meeting, progress: 0.4), true),
            (nil, .summarizing(meetingID: Self.meeting), true),
            (.saved, .idle, true),
            (nil, .idle, false),
        ]
        for step in steps {
            let face = IslandShellFace.resolve(detection: step.detection, phase: step.phase)
            #expect(
                face.isOnScreen(hasCutout: false, hovered: false) == step.onScreen,
                "\(face) from \(String(describing: step.detection))/\(step.phase)")
        }
    }

    @Test("a screen without one shows the island only while it has something to say")
    func theBareScreenShowsOnlyNews() {
        // The reported case: a black bar over the top of the desktop for the
        // whole life of the app, saying nothing.
        #expect(!IslandShellFace.idle.isOnScreen(hasCutout: false, hovered: false))
        for face in IslandShellFace.allCases where face.announces {
            #expect(face.isOnScreen(hasCutout: false, hovered: false), "\(face) had news and hid")
        }
    }

    @Test("and it is never taken out from under a pointer that is on it")
    func hoverHoldsTheIslandOnScreen() {
        // The same rule that defers a move between screens. It also keeps the
        // grace honest: ordering the window out from under the pointer leaves
        // nothing to send the crossing that would correct it.
        #expect(IslandShellFace.idle.isOnScreen(hasCutout: false, hovered: true))
    }

    @Test("idle is the only face with nothing to announce")
    func onlyIdleIsSilent() {
        for face in IslandShellFace.allCases {
            #expect(face.announces == (face != .idle), "\(face)")
        }
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

    // MARK: - The face that hides in the hole

    @Test("the idle shell, flares and all, is exactly the cutout")
    func theIdleShellHidesInTheCutout() {
        // What the user sees of the idle island is what falls OUTSIDE the
        // cutout, and the answer has to be nothing: the physical notch is
        // already black, so a shell that ends where it ends is invisible, and
        // one point past it is a black tab on the bezel for the whole life of
        // the app.
        //
        // The window is the measure, not the shell: the flares are drawn
        // outside the shell's own width, and `panelSize` is the only number
        // that counts both.
        let metrics = IslandMetrics(Self.notched)
        let cutout = try! #require(metrics.cutout)
        let geometry = IslandShellGeometry(metrics: metrics, face: .idle, isExpanded: false)

        #expect(geometry.panelSize.width == cutout.width)
        #expect(geometry.shellSize.width == cutout.width)
        #expect(geometry.shellSize.height == cutout.height)

        let frame = geometry.panelFrame(on: metrics)
        #expect(frame.maxY == metrics.screenFrame.maxY)
        #expect(frame.width <= cutout.width, "black on the bezel either side of the notch")
    }

    @Test("the idle shell has no flares, because there is nothing to pour from")
    func theIdleShellHasNoFlares() {
        // A flare is black drawn OUTSIDE the shell, and outside the hole there
        // is only bezel. So the shell takes the cutout's own outline and the
        // flares grow in with the expansion — which is why the shape animates
        // the flare rather than stepping it.
        let metrics = IslandMetrics(Self.notched)
        let cutout = try! #require(metrics.cutout)

        let shut = IslandShellGeometry(metrics: metrics, face: .idle, isExpanded: false)
        #expect(shut.flare == 0)
        #expect(shut.shellSize.width == cutout.width)

        let open = IslandShellGeometry(metrics: metrics, face: .idle, isExpanded: true)
        #expect(open.flare == EchoLayout.islandFlare)
    }

    @Test("a face with ears keeps its flares while collapsed")
    func theAnnouncingFacesKeepTheirFlares() {
        // They hang off the bezel rather than hiding in the hole, and the
        // flare is what makes them read as poured from it.
        let metrics = IslandMetrics(Self.notched)
        for face in IslandShellFace.allCases where face.announces {
            let geometry = IslandShellGeometry(metrics: metrics, face: face, isExpanded: false)
            #expect(geometry.flare == EchoLayout.islandFlare, "\(face)")
        }
    }

    @Test("the expanded row clears the cutout, which is not screen to draw on")
    func theRowHangsBelowTheHole() {
        let metrics = IslandMetrics(Self.notched)
        let cutout = try! #require(metrics.cutout)
        for face in IslandShellFace.allCases {
            let geometry = IslandShellGeometry(metrics: metrics, face: face, isExpanded: true)
            #expect(geometry.rowTopInset == cutout.height, "\(face)")
            // And something is left to put the row in.
            #expect(geometry.shellSize.height > geometry.rowTopInset, "\(face)")
        }
        // A screen with no cutout has nothing in the way.
        #expect(
            IslandShellGeometry(metrics: .init(Self.noCutout), face: .idle, isExpanded: true)
                .rowTopInset == 0)
    }

    @Test("a face with something to say is still as wide as the design draws it")
    func theAnnouncingFacesAreUnchanged() {
        // Only the idle face hides in the hole. Every other one has content in
        // its ears, which is exactly why it is wider than the cutout.
        let metrics = IslandMetrics(Self.notched)
        let cutout = try! #require(metrics.cutout)
        for face in IslandShellFace.allCases where face.announces {
            let geometry = IslandShellGeometry(metrics: metrics, face: face, isExpanded: false)
            #expect(geometry.shellSize.width == face.width.collapsed, "\(face)")
            #expect(geometry.shellSize.width > cutout.width, "\(face) has no ears to put anything in")
        }
    }

    @Test("expanding is the same for every face, idle included")
    func expandingIsUnchanged() {
        let metrics = IslandMetrics(Self.notched)
        for face in IslandShellFace.allCases {
            let geometry = IslandShellGeometry(metrics: metrics, face: face, isExpanded: true)
            #expect(geometry.shellSize.width == face.width.expanded, "\(face)")
            #expect(geometry.shellSize.height == EchoLayout.islandExpandedHeight, "\(face)")
        }
    }

    @Test("the hole the ears split around belongs to the screen, not to a state")
    func theCutoutIsTheScreensAndNotTheStates() {
        // The ears go on holding their places either side of the cutout for as
        // long as they are still on screen, and they are still on screen while
        // the shell opens. A hole that vanished the instant it began would
        // take them with it, mid-fade.
        let metrics = IslandMetrics(Self.notched)
        for isExpanded in [false, true] {
            #expect(
                IslandShellGeometry(metrics: metrics, face: .recording, isExpanded: isExpanded)
                    .cutoutWidth == metrics.cutout?.width)
        }
        // A screen with no cutout has no hole in either state.
        for isExpanded in [false, true] {
            #expect(
                IslandShellGeometry(metrics: .init(Self.noCutout), face: .recording, isExpanded: isExpanded)
                    .cutoutWidth == nil)
        }
    }

    @Test("hovering the notch opens from its edges, not from somewhere behind it")
    func theFirstHoverOpensFromTheNotchsEdges() {
        // The hover animation defect, as geometry. Hovering the idle shell is
        // the ONLY way it ever opens, so what the expansion starts from is
        // what a hover looks like — and it was starting from a shell narrower
        // than the hole, hidden behind the notch until it had grown past it.
        //
        // A flare only ever adds black ABOVE the band it occupies: below it,
        // what is drawn is the shell's own width. So a shell whose body was
        // the cutout MINUS both flares came out to the hole's edge at its top
        // edge and was narrower than the hole everywhere under it — the first
        // part of every expansion happened behind the notch, the top corners
        // appearing only once the shell had grown past them. Reported from a
        // 14" M4 Pro as the shell being cut.
        //
        // The body is therefore the assertion that matters. The bounding box
        // agreeing is necessary and nowhere near sufficient: it agreed before.
        let metrics = IslandMetrics(Self.notched)
        let cutout = try! #require(metrics.cutout)
        let geometry = IslandShellGeometry(metrics: metrics, face: .idle, isExpanded: false)

        #expect(geometry.shellSize.width == cutout.width, "narrower than the hole below its top edge")

        let path = IslandShellShape(cornerRadius: geometry.cornerRadius, flare: geometry.flare)
            .path(in: CGRect(origin: .zero, size: geometry.shellSize))
        #expect(abs(path.boundingRect.width - cutout.width) < 0.5)
        // Below any flare band there would be, the shape still reaches both
        // edges of the hole.
        let deep = EchoLayout.islandFlare + 1
        #expect(path.contains(CGPoint(x: 0.5, y: deep)))
        #expect(path.contains(CGPoint(x: geometry.shellSize.width - 0.5, y: deep)))
    }

    @Test("two screens are two shells, so the spring is never asked to cross between them")
    func eachScreenIsItsOwnShell() {
        // The blink: a notched shell on one display and a pill on another are
        // different widths, heights, radii, flares and shadows, and the window
        // has already teleported by the time the spring is handed the move.
        // The shell carries the screen's identity so the crossing is a cut.
        #expect(IslandMetrics(Self.notched).displayID != IslandMetrics(Self.noCutout).displayID)
    }

    @Test("which outline is drawn follows the screen, never the flare")
    func theOutlineFollowsTheScreen() {
        // The regression this exists for: the idle shell has no flares, and a
        // view choosing its shape by asking whether there was one sent the
        // shell whose top edge is flush with the top of the SCREEN to the
        // floating pill's rounded rectangle, rounding two corners the design
        // says are always square.
        let notched = IslandMetrics(Self.notched)
        for face in IslandShellFace.allCases {
            for isExpanded in [false, true] {
                let geometry = IslandShellGeometry(metrics: notched, face: face, isExpanded: isExpanded)
                #expect(geometry.hangsFromBezel, "\(face) \(isExpanded ? "open" : "shut")")
            }
        }
        // And the one that genuinely floats does not.
        #expect(
            !IslandShellGeometry(metrics: .init(Self.noCutout), face: .idle, isExpanded: false)
                .hangsFromBezel)
        // The flare is not the question: the shell that hangs has none while
        // it is hiding in the hole.
        let shut = IslandShellGeometry(metrics: notched, face: .idle, isExpanded: false)
        #expect(shut.flare == 0 && shut.hangsFromBezel)
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
        // A face with ears, deliberately: the idle shell is exactly as wide as
        // the cutout now, so its origin comes out whole and it cannot show
        // what this test is about.
        let metrics = IslandMetrics(Self.notched)
        let geometry = IslandShellGeometry(metrics: metrics, face: .recording, isExpanded: false)
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

    @Test("a shell smaller than its window hangs from the top of it, never floats in the middle")
    func theShellHangsFromTheTop() throws {
        // The state this is about is the middle of an expansion: the window
        // has already taken the room the open shell will need, and the shell
        // inside it is still small. Hung from the top, the black is against
        // the bezel and grows downward out of the notch. Centred, it starts
        // below the notch and rises into it, which is what was reported.
        let metrics = IslandMetrics(Self.notched)
        let shut = IslandShellGeometry(metrics: metrics, face: .idle, isExpanded: false)
        let open = IslandShellGeometry(metrics: metrics, face: .idle, isExpanded: true)
        #expect(open.panelSize.height > shut.panelSize.height, "the fixture stopped being the case")

        let rendered = try image(
            of: IslandShell(
                geometry: shut,
                isExpanded: false,
                leadingEar: { Color.clear },
                trailingEar: { Color.clear },
                row: { Color.clear }
            ),
            size: open.panelSize
        )

        let middle = rendered.width / 2
        #expect(try isOpaque(rendered, atX: middle, y: 2), "nothing against the top of the window")
        #expect(
            try !isOpaque(rendered, atX: middle, y: rendered.height - 3),
            "the shell reaches the bottom, so this proves nothing about where it hangs")
        // The last row of the shell itself, and the first row past it.
        let shellBottom = Int(shut.panelSize.height) * 2
        #expect(try isOpaque(rendered, atX: middle, y: shellBottom - 3))
        #expect(
            try !isOpaque(rendered, atX: middle, y: shellBottom + 3),
            "the shell is lower than the top of its window")
    }

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
                let panel = IslandShellGeometry(metrics: metrics, face: face, isExpanded: isExpanded)
                    .panelSize
                let light = try image(of: shell.environment(\.colorScheme, .light), size: panel)
                let dark = try image(of: shell.environment(\.colorScheme, .dark), size: panel)
                // A blank pair matches a blank pair: without this the test
                // passes on two empty images, which is what it did the moment
                // the shell's root became something with no ideal size.
                #expect(light.width == Int(panel.width) * 2, "\(face) rendered at the wrong size")
                #expect(try isOpaque(light, atX: light.width / 2, y: 2), "\(face) rendered nothing")
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

    /// Renders at an explicit size, because the shell fills what it is given
    /// rather than asserting a size of its own — exactly as it does inside its
    /// window. Rendered with no size it collapses to nothing.
    private func image(of view: some View, size: CGSize) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    /// Whether the rendered pixel is drawn at all, which for the shell means
    /// black rather than nothing. The alpha byte is wherever the renderer put
    /// it, so ask rather than assume.
    private func isOpaque(_ image: CGImage, atX x: Int, y: Int) throws -> Bool {
        let data = try #require(image.dataProvider?.data as Data?)
        let bytesPerPixel = image.bitsPerPixel / 8
        let offset = y * image.bytesPerRow + x * bytesPerPixel
        try #require(offset + bytesPerPixel <= data.count)
        let alphaFirst =
            image.alphaInfo == .premultipliedFirst || image.alphaInfo == .first
            || image.alphaInfo == .noneSkipFirst
        return data[alphaFirst ? offset : offset + bytesPerPixel - 1] > 0
    }
}
