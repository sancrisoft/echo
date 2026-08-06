//
//  CaptureScopeResolutionTests.swift
//  EchoTests
//
//  SP-008 / ADR-026: what a recording's scope *is* (CaptureScope) and which
//  process objects a scoped tap includes. Resolution rides the same
//  `CallApp.matches(bundleID:)` the detection catalog is tested on — these
//  tables extend `CallAppCatalogTests` to the scoping side of that promise
//  rather than duplicating the matcher rows: helpers join their parent app's
//  tap, near-misses and nameless processes never do, and an app with no live
//  processes resolves to the *legal* empty set (silence, not failure).
//

import CoreAudio
import Testing
@testable import Echo

struct CaptureScopeResolutionTests {

    private let zoom = CallApp(displayName: "Zoom", bundlePrefix: "us.zoom.xos")
    private let chrome = CallApp(displayName: "Google Chrome", bundlePrefix: "com.google.Chrome")

    private typealias Entry = ScopedProcessResolution.ProcessEntry

    // MARK: - CaptureScope

    @Test func indicatorLabelForGlobalScopeIsEverything() {
        // Settled copy (SP-008 open question 4): the word every recording
        // surface shows for an unscoped session.
        #expect(CaptureScope.everything.indicatorLabel == "Everything")
    }

    @Test func indicatorLabelForScopedSessionNamesTheApp() {
        // "Zoom only" — the honest label: browsers say the browser's name,
        // never the meeting service inside it.
        #expect(CaptureScope.app(zoom).indicatorLabel == "Zoom only")
        #expect(CaptureScope.app(chrome).indicatorLabel == "Google Chrome only")
    }

    @Test func scopedAppRoundTrips() {
        // The capture layer reads back exactly the app the scope was built
        // with; a global session has none.
        #expect(CaptureScope.everything.scopedApp == nil)
        #expect(CaptureScope.app(zoom).scopedApp == zoom)
    }

    // MARK: - Include-set resolution

    @Test func exactBundleIDIsIncluded() {
        let processes: [Entry] = [
            Entry(object: 10, bundleID: "us.zoom.xos"),
            Entry(object: 11, bundleID: "com.spotify.client"),
        ]
        #expect(ScopedProcessResolution.includeSet(for: zoom, in: processes) == [10])
    }

    @Test func helperProcessesJoinTheirParentAppsSet() {
        // The whole reason scope is a bundle prefix, never a PID (ADR-026):
        // browsers and Electron apps play audio from helper processes.
        let processes: [Entry] = [
            Entry(object: 20, bundleID: "com.google.Chrome"),
            Entry(object: 21, bundleID: "com.google.Chrome.helper"),
            Entry(object: 22, bundleID: "com.google.Chrome.helper.renderer"),
        ]
        #expect(ScopedProcessResolution.includeSet(for: chrome, in: processes) == [20, 21, 22])
    }

    @Test func neighbouringIdentifiersStayOut() {
        // The "." in the prefix rule again: a different product sharing a
        // naming stem must never leak into a scoped recording.
        let processes: [Entry] = [
            Entry(object: 30, bundleID: "com.google.Chromium"),
            Entry(object: 31, bundleID: "com.google.Chromecast"),
        ]
        #expect(ScopedProcessResolution.includeSet(for: chrome, in: processes).isEmpty)
    }

    @Test func anEmptyBundleIDNeverJoinsAScopedTap() {
        // Daemons and unbundled processes report no bundle ID; a nameless
        // process can never be part of "record this app".
        let processes: [Entry] = [Entry(object: 40, bundleID: "")]
        #expect(ScopedProcessResolution.includeSet(for: zoom, in: processes).isEmpty)
    }

    @Test func anAppWithNoProcessesResolvesToTheLegalEmptySet() {
        // Not a failure (ADR-026): the app quit, is relaunching, or has not
        // played yet — the scoped tap records silence until it (re)appears.
        #expect(ScopedProcessResolution.includeSet(for: zoom, in: []).isEmpty)
    }

    @Test func twoCataloguedAppsResolveDisjointSetsFromOneMixedList() {
        // A Zoom meeting and a Chrome tab side by side: each app's scope sees
        // only its own processes, and nobody claims the uncatalogued rest.
        let mixed: [Entry] = [
            Entry(object: 50, bundleID: "us.zoom.xos"),
            Entry(object: 51, bundleID: "us.zoom.xos.aomhost"),
            Entry(object: 52, bundleID: "com.google.Chrome.helper"),
            Entry(object: 53, bundleID: "com.spotify.client"),
            Entry(object: 54, bundleID: ""),
        ]
        let zoomSet = ScopedProcessResolution.includeSet(for: zoom, in: mixed)
        let chromeSet = ScopedProcessResolution.includeSet(for: chrome, in: mixed)
        #expect(zoomSet == [50, 51])
        #expect(chromeSet == [52])
        #expect(zoomSet.isDisjoint(with: chromeSet))
    }
}
