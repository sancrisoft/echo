//
//  CallAppFilterTests.swift
//  EchoTests
//
//  Per-app call detection (§3.7): the disabled-apps filter sits at the single
//  matcher call site (`CallDetectionController.matchedApps`), keyed on
//  display names — one name covers all of an app's bundle prefixes, a stale
//  name is harmlessly ignored, and an empty set is byte-for-byte today's
//  matching. What this function returns IS what feeds the machine's
//  `matchedAppsChanged`, so a filtered-out app can never reach the island or
//  the scope dropdown.
//

import Foundation
import Testing
@testable import Echo

@Suite("Call detection — per-app filter")
@MainActor
struct CallAppFilterTests {

    private func client(_ bundleID: String, pid: pid_t = 100) -> MicActivityMonitor.Client {
        MicActivityMonitor.Client(pid: pid, bundleID: bundleID)
    }

    @Test func anEmptyDisabledSetMatchesExactlyAsToday() {
        let clients = [client("us.zoom.xos"), client("com.hnc.Discord", pid: 101)]
        let apps = CallDetectionController.matchedApps(from: clients)
        #expect(apps.map(\.displayName) == ["Zoom", "Discord"])
    }

    /// Teams owns two bundle prefixes; one disabled NAME must cover both.
    @Test func oneDisabledNameCoversAllOfTeamsPrefixes() {
        let clients = [
            client("com.microsoft.teams2", pid: 100),
            client("com.microsoft.teams", pid: 101),
            client("us.zoom.xos", pid: 102),
        ]
        let apps = CallDetectionController.matchedApps(
            from: clients,
            disabledNames: ["Microsoft Teams"]
        )
        #expect(apps.map(\.displayName) == ["Zoom"])
    }

    /// FaceTime's pair: the app process and the AV conferencing daemon both
    /// attribute to one name — one checkbox silences both.
    @Test func oneDisabledNameCoversFaceTimesAppAndDaemon() {
        let clients = [
            client("com.apple.FaceTime", pid: 100),
            client("com.apple.avconferenced", pid: 101),
        ]
        let apps = CallDetectionController.matchedApps(
            from: clients,
            disabledNames: ["FaceTime"]
        )
        #expect(apps.isEmpty)
    }

    /// A name the catalog no longer carries (a rename) matches nothing and
    /// breaks nothing.
    @Test func aStaleDisabledNameIsIgnored() {
        let clients = [client("us.zoom.xos")]
        let apps = CallDetectionController.matchedApps(
            from: clients,
            disabledNames: ["Zoom Workplace (old name)", "Skype"]
        )
        #expect(apps.map(\.displayName) == ["Zoom"])
    }

    @Test func disablingOneAppLeavesTheOthersDetected() {
        let clients = [
            client("com.hnc.Discord", pid: 100),
            client("us.zoom.xos", pid: 101),
        ]
        let apps = CallDetectionController.matchedApps(
            from: clients,
            disabledNames: ["Discord"]
        )
        #expect(apps.map(\.displayName) == ["Zoom"])
    }

    /// The Settings rows: unique names, in catalog (attribution) order —
    /// multi-prefix apps appear exactly once.
    @Test func uniqueDisplayNamesDedupeMultiPrefixApps() {
        let names = CallAppCatalog.uniqueDisplayNames
        #expect(names.count == Set(names).count)
        #expect(names.filter { $0 == "Microsoft Teams" }.count == 1)
        #expect(names.filter { $0 == "FaceTime" }.count == 1)
        #expect(names.filter { $0 == "Safari" }.count == 1)
        // Order of first appearance: native apps before browsers.
        #expect(names.first == "Zoom")
        #expect(names.contains("Google Chrome"))
    }
}
