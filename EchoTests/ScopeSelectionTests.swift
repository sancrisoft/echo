//
//  ScopeSelectionTests.swift
//  EchoTests
//
//  SP-008: the menu-bar popup's scope selector derives its options purely from
//  `CallDetectionController.appsInCall` — the same deduped, catalog-ordered
//  list the island attributes from. These tables pin that there is no second
//  detection path: what the popup offers, in what order, and what it
//  preselects are all functions of that one list.
//

import Testing
@testable import Echo

struct ScopeSelectionTests {

    // Real catalogue entries, so the tables exercise the same values the
    // popup will see (and stay honest if the catalogue ever changes).
    private let zoom = CallAppCatalog.match(bundleID: "us.zoom.xos")!
    private let chrome = CallAppCatalog.match(bundleID: "com.google.Chrome")!
    /// The one unscopeable entry (SP-008 open question 3): a call attributed
    /// to Apple's AV conferencing daemon can only be recorded as Everything.
    private let faceTimeDaemon = CallAppCatalog.match(bundleID: "com.apple.avconferenced")!

    // MARK: - One call

    @Test func oneCallOffersThatAppThenEverything() {
        #expect(ScopeSelection.options(appsInCall: [zoom]) == [.app(zoom), .everything])
    }

    @Test func oneCallPreselectsTheDetectedApp() {
        #expect(ScopeSelection.defaultSelection(appsInCall: [zoom]) == .app(zoom))
    }

    // MARK: - Two simultaneous calls

    @Test func twoCallsOfferBothAppsInCatalogOrderThenEverything() {
        // `appsInCall` arrives already in catalog order (Zoom outranks
        // browsers); the selector preserves it so the popup and the island
        // tell the same story.
        #expect(
            ScopeSelection.options(appsInCall: [zoom, chrome])
                == [.app(zoom), .app(chrome), .everything]
        )
    }

    @Test func twoCallsPreselectTheFirstApp() {
        // The FIRST element is the app the island names — the preselection
        // must match that attribution, never re-derive its own.
        #expect(ScopeSelection.defaultSelection(appsInCall: [zoom, chrome]) == .app(zoom))
    }

    // MARK: - No call

    @Test func noCallMeansNoSelector() {
        #expect(ScopeSelection.options(appsInCall: []) == [])
        #expect(ScopeSelection.defaultSelection(appsInCall: []) == nil)
    }

    // MARK: - Unscopeable apps (SP-008 open question 3)

    @Test func anUnscopeableAppAloneMeansNoSelector() {
        // Everything-only is exactly today's popup, so rendering a one-option
        // selector would be noise: no selector row at all.
        #expect(ScopeSelection.options(appsInCall: [faceTimeDaemon]) == [])
        #expect(ScopeSelection.defaultSelection(appsInCall: [faceTimeDaemon]) == nil)
    }

    @Test func anUnscopeableAppIsFilteredOutNextToAScopeableOne() {
        // Catalog order puts the daemon before Chrome, so this also pins that
        // the preselection is the first *scopeable* app — not just the first.
        #expect(
            ScopeSelection.options(appsInCall: [faceTimeDaemon, chrome])
                == [.app(chrome), .everything]
        )
        #expect(
            ScopeSelection.defaultSelection(appsInCall: [faceTimeDaemon, chrome]) == .app(chrome)
        )
    }
}
