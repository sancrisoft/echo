//
//  ScopeSelectionTests.swift
//  IslandTests
//
//  The capture chip derives its choices purely from `CallDetector.appsInCall`
//  — the same deduped, catalog-ordered list the island attributes from. These
//  tables pin that there is no second detection path: what the chip offers, in
//  what order, and what it preselects are all functions of that one list.
//
//  Ported from the PoC's ScopeSelectionTests. Two cases changed with the
//  surface, and say so: the island always shows the chip, so "no call" offers
//  Everything alone instead of nothing.
//

import Audio
import CallDetection
import Testing

@testable import Island

@Suite("What the capture chip offers")
struct ScopeSelectionTests {

    // Real catalogue entries, so the tables exercise the values the chip will
    // see, and stay honest if the catalogue changes. Required rather than
    // unwrapped: an entry that leaves the catalogue fails each case by name
    // instead of crashing the run.
    private let zoom: ProcessSelector
    private let chrome: ProcessSelector
    /// The one unscopeable entry: a call attributed to Apple's AV
    /// conferencing daemon can only be recorded as Everything.
    private let faceTimeDaemon: ProcessSelector

    init() throws {
        zoom = try #require(CallAppCatalog.match(bundleID: "us.zoom.xos"))
        chrome = try #require(CallAppCatalog.match(bundleID: "com.google.Chrome"))
        faceTimeDaemon = try #require(CallAppCatalog.match(bundleID: "com.apple.avconferenced"))
    }

    // MARK: One call

    @Test("one call offers that app, then Everything")
    func oneCall() {
        #expect(ScopeSelection.options(appsInCall: [zoom]) == [.app(zoom), .everything])
    }

    @Test("one call preselects the detected app")
    func oneCallPreselects() {
        #expect(ScopeSelection.defaultSelection(appsInCall: [zoom]) == .app(zoom))
    }

    // MARK: Two calls at once

    @Test("two calls offer both apps in catalog order, then Everything")
    func twoCalls() {
        #expect(
            ScopeSelection.options(appsInCall: [zoom, chrome]) == [.app(zoom), .app(chrome), .everything]
        )
    }

    /// The FIRST element is the app the island names; the preselection must
    /// match that attribution, never re-derive its own.
    @Test("two calls preselect the first app")
    func twoCallsPreselect() {
        #expect(ScopeSelection.defaultSelection(appsInCall: [zoom, chrome]) == .app(zoom))
    }

    // MARK: No call — changed from the PoC

    @Test("no call offers Everything alone, and the chip still shows it")
    func noCall() {
        #expect(ScopeSelection.options(appsInCall: []) == [.everything])
        #expect(ScopeSelection.defaultSelection(appsInCall: []) == .everything)
    }

    // MARK: Unscopeable apps

    @Test("an unscopeable app alone leaves Everything alone")
    func unscopeableAlone() {
        #expect(ScopeSelection.options(appsInCall: [faceTimeDaemon]) == [.everything])
        #expect(ScopeSelection.defaultSelection(appsInCall: [faceTimeDaemon]) == .everything)
    }

    /// Catalog order puts the daemon before Chrome, so this also pins that the
    /// preselection is the first *scopeable* app, not just the first.
    @Test("an unscopeable app is left out beside a scopeable one")
    func unscopeableBesideScopeable() {
        #expect(ScopeSelection.options(appsInCall: [faceTimeDaemon, chrome]) == [.app(chrome), .everything])
        #expect(ScopeSelection.defaultSelection(appsInCall: [faceTimeDaemon, chrome]) == .app(chrome))
    }

    // MARK: A pick, and how long it lasts

    @Test("a pick holds while its app is still in the call")
    func pickHolds() {
        #expect(ScopeSelection.effective(picked: .everything, appsInCall: [zoom]) == .everything)
        #expect(ScopeSelection.effective(picked: .app(chrome), appsInCall: [zoom, chrome]) == .app(chrome))
    }

    @Test("a pick whose app left falls back to the default")
    func pickFallsBack() {
        #expect(ScopeSelection.effective(picked: .app(chrome), appsInCall: [zoom]) == .app(zoom))
        #expect(ScopeSelection.effective(picked: .app(zoom), appsInCall: []) == .everything)
    }

    @Test("no pick is the default")
    func noPick() {
        #expect(ScopeSelection.effective(picked: nil, appsInCall: [zoom]) == .app(zoom))
    }

    // MARK: Labels

    @Test("a choice reads as what it captures")
    func labels() {
        #expect(ScopeSelection.label(for: .everything) == "Everything")
        #expect(ScopeSelection.label(for: .app(zoom)) == "Zoom only")
    }
}
