//
//  ScopeFollowTests.swift
//  EchoTests
//
//  SP-008 / ADR-026: when a process-list change must touch the live scoped
//  tap. The contract is asymmetric on purpose — `nil` means "the tap already
//  tells the truth, write nothing", so unrelated process churn (and Core
//  Audio's habit of re-reporting the same list) never costs a property write;
//  a non-nil set is applied exactly once per real change, including the empty
//  set when the app fully exits, which is silence to record through, never a
//  failure to handle (the SP-006 end-grace flow owns what happens next).
//

import CoreAudio
import Testing
@testable import Echo

struct ScopeFollowTests {

    private let zoom = CallApp(displayName: "Zoom", bundlePrefix: "us.zoom.xos")

    private typealias Entry = ScopedProcessResolution.ProcessEntry

    /// A mid-call Zoom session: the main process and its audio helper.
    private let currentSet: Set<AudioObjectID> = [50, 51]

    @Test func helperAppearingGrowsTheSetInOneUpdate() {
        // A browser spawning a new audio process (or Zoom starting a
        // screen-share module) must join the tap — silently dropping it is
        // the worst failure shape this feature has (ADR-026).
        let processes: [Entry] = [
            Entry(object: 50, bundleID: "us.zoom.xos"),
            Entry(object: 51, bundleID: "us.zoom.xos.aomhost"),
            Entry(object: 53, bundleID: "com.spotify.client"),
        ]
        let update = ScopedProcessResolution.followUpdate(for: zoom, current: [50], processes: processes)
        #expect(update == [50, 51])
    }

    @Test func helperExitingShrinksTheSetInOneUpdate() {
        let processes: [Entry] = [
            Entry(object: 50, bundleID: "us.zoom.xos"),
            Entry(object: 53, bundleID: "com.spotify.client"),
        ]
        let update = ScopedProcessResolution.followUpdate(for: zoom, current: currentSet, processes: processes)
        #expect(update == [50])
    }

    @Test func unrelatedProcessChurnNeverTouchesTheTap() {
        // Other apps launching and quitting fire the process-list listener
        // constantly; none of it may reach the tap (SP-008 performance NFR:
        // scope logic runs on set changes only).
        let processes: [Entry] = [
            Entry(object: 50, bundleID: "us.zoom.xos"),
            Entry(object: 60, bundleID: "com.apple.Music"),
            Entry(object: 61, bundleID: ""),
        ]
        #expect(ScopedProcessResolution.followUpdate(for: zoom, current: [50], processes: processes) == nil)
    }

    @Test func appFullyExitingUpdatesToTheEmptySetNotAFailure() {
        // "App died and I kept recording" is a legal state (ADR-026): the tap
        // narrows to nothing and records silence; a relaunch grows it back.
        let processes: [Entry] = [Entry(object: 53, bundleID: "com.spotify.client")]
        let update = ScopedProcessResolution.followUpdate(for: zoom, current: currentSet, processes: processes)
        #expect(update?.isEmpty == true)
    }

    @Test func identicalListReReportedIsNoUpdate() {
        // Core Audio may notify without a real diff; the same truth twice
        // must not become two property writes.
        let processes: [Entry] = [
            Entry(object: 50, bundleID: "us.zoom.xos"),
            Entry(object: 51, bundleID: "us.zoom.xos.aomhost"),
        ]
        #expect(ScopedProcessResolution.followUpdate(for: zoom, current: currentSet, processes: processes) == nil)
    }
}
