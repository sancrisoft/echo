//
//  CaptureScopeMappingTests.swift
//  RecordingTests
//
//  The one place a live session's coverage becomes what a finished meeting
//  records. Small, but it is the boundary between two packages that never see
//  each other, so both directions of the mapping are pinned here.
//

import Audio
import Meetings
import Testing

@testable import Recording

@Suite("Capture scope → meeting record")
struct CaptureScopeMappingTests {

    @Test func everythingMapsToTheEverythingRecord() {
        #expect(CaptureScopeRecord(capturing: .everything) == .everything)
        #expect(CaptureScopeRecord(capturing: .everything).kind == CaptureScopeRecord.everythingKind)
        // A global session names no app, so the row shows no caption at all.
        #expect(CaptureScopeRecord(capturing: .everything).appName == nil)
        #expect(CaptureScopeRecord(capturing: .everything).scopedDisplayLabel == nil)
    }

    @Test func anAppScopeKeepsOnlyTheDisplayName() {
        let selector = ProcessSelector(displayName: "Zoom", bundlePrefix: "us.zoom.xos")
        let record = CaptureScopeRecord(capturing: .app(selector))

        #expect(record.kind == CaptureScopeRecord.appKind)
        // The display name, never the selector: a bundle prefix is a matching
        // rule a future build may change, "Zoom" is what the row must still
        // say a year from now.
        #expect(record.appName == selector.displayName)
        #expect(record.scopedDisplayLabel == "Zoom only")
    }
}
