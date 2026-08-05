//
//  CallAppCatalogTests.swift
//  EchoTests
//
//  SP-006 / ADR-017: only a curated set of meeting apps and browsers counts as
//  "the user is in a call". These tables pin both halves of that promise — the
//  catalogued apps (including their helper processes) match, and everything
//  else, especially near-miss identifiers, does not.
//

import Testing
@testable import Echo

struct CallAppCatalogTests {

    // MARK: - Catalogued apps

    @Test func everyCatalogueEntryMatchesItsOwnBundleID() {
        for app in CallAppCatalog.apps {
            #expect(
                CallAppCatalog.match(bundleID: app.bundlePrefix) != nil,
                "catalogued app \(app.displayName) does not match its own prefix"
            )
        }
    }

    @Test func meetingAppsMatchByName() {
        #expect(CallAppCatalog.match(bundleID: "us.zoom.xos")?.displayName == "Zoom")
        #expect(CallAppCatalog.match(bundleID: "com.microsoft.teams2")?.displayName == "Microsoft Teams")
        #expect(CallAppCatalog.match(bundleID: "com.microsoft.teams")?.displayName == "Microsoft Teams")
        #expect(CallAppCatalog.match(bundleID: "com.tinyspeck.slackmacgap")?.displayName == "Slack")
        #expect(CallAppCatalog.match(bundleID: "com.hnc.Discord")?.displayName == "Discord")
        #expect(CallAppCatalog.match(bundleID: "com.apple.FaceTime")?.displayName == "FaceTime")
        #expect(CallAppCatalog.match(bundleID: "Cisco-Systems.Spark")?.displayName == "Webex")
    }

    @Test func browsersMatchByName() {
        #expect(CallAppCatalog.match(bundleID: "com.google.Chrome")?.displayName == "Google Chrome")
        #expect(CallAppCatalog.match(bundleID: "com.microsoft.edgemac")?.displayName == "Microsoft Edge")
        #expect(CallAppCatalog.match(bundleID: "com.brave.Browser")?.displayName == "Brave")
        #expect(CallAppCatalog.match(bundleID: "company.thebrowser.Browser")?.displayName == "Arc")
        #expect(CallAppCatalog.match(bundleID: "org.mozilla.firefox")?.displayName == "Firefox")
        #expect(CallAppCatalog.match(bundleID: "com.apple.Safari")?.displayName == "Safari")
        // WebKit's GPU process is where Safari's media capture actually runs.
        #expect(CallAppCatalog.match(bundleID: "com.apple.WebKit.GPU")?.displayName == "Safari")
    }

    // MARK: - Helper processes attribute to their parent app

    @Test func helperProcessesAttributeToTheirParentApp() {
        // Browsers capture from a helper process, and Zoom spawns its own —
        // the whole reason matching is prefix-based (ADR-017).
        #expect(CallAppCatalog.match(bundleID: "com.google.Chrome.helper")?.displayName == "Google Chrome")
        #expect(CallAppCatalog.match(bundleID: "com.google.Chrome.helper.renderer")?.displayName == "Google Chrome")
        #expect(CallAppCatalog.match(bundleID: "us.zoom.xos.helper")?.displayName == "Zoom")
        #expect(CallAppCatalog.match(bundleID: "com.brave.Browser.helper")?.displayName == "Brave")
    }

    // MARK: - Near misses must not match

    @Test func neighbouringIdentifiersDoNotMatch() {
        // The "." in the prefix rule is what separates a helper process from a
        // different product that merely shares a naming stem.
        #expect(CallAppCatalog.match(bundleID: "com.google.Chromecast") == nil)
        #expect(CallAppCatalog.match(bundleID: "com.google.Chromium") == nil)
        #expect(CallAppCatalog.match(bundleID: "com.microsoft.teamsy") == nil)
        #expect(CallAppCatalog.match(bundleID: "com.apple.SafariTechnologyPreview") == nil)
        #expect(CallAppCatalog.match(bundleID: "com.apple.FaceTimeFoo") == nil)
    }

    @Test func nonCallMicrophoneUseNeverMatches() {
        // The false-positive containment the whole feature rests on: dictation,
        // voice memos and voice assistants are invisible to detection.
        #expect(CallAppCatalog.match(bundleID: "com.apple.SpeechRecognitionCore.speechrecognitiond") == nil)
        #expect(CallAppCatalog.match(bundleID: "com.apple.VoiceMemos") == nil)
        #expect(CallAppCatalog.match(bundleID: "com.apple.assistantd") == nil)
        #expect(CallAppCatalog.match(bundleID: "com.apple.QuickTimePlayerX") == nil)
        #expect(CallAppCatalog.match(bundleID: "com.sancrisoft.Echo") == nil)
    }

    @Test func screenRecordingIsNotACall() {
        // `replayd` captures the microphone while the screen is being recorded
        // — seen for six minutes during SP-006's real-call session. Recording
        // your screen is not being in a meeting.
        #expect(CallAppCatalog.match(bundleID: "com.apple.replayd") == nil)
    }

    @Test func faceTimeMatchesTheDaemonThatActuallyCaptures() {
        // Measured on real calls: the FaceTime app process never opens the mic,
        // Apple's AV conferencing daemon does, and it goes quiet within two
        // seconds of hanging up (SP-006 open question 1).
        #expect(CallAppCatalog.match(bundleID: "com.apple.avconferenced")?.displayName == "FaceTime")
        #expect(CallAppCatalog.match(bundleID: "com.apple.FaceTime")?.displayName == "FaceTime")
    }

    @Test func anEmptyBundleIDNeverMatches() {
        // Daemons and unbundled processes report no bundle ID; a nameless
        // capture must never be read as a call.
        #expect(CallAppCatalog.match(bundleID: "") == nil)
    }

    @Test func matchingIsCaseSensitive() {
        // Bundle IDs are compared exactly as Core Audio reports them.
        #expect(CallAppCatalog.match(bundleID: "US.ZOOM.XOS") == nil)
        #expect(CallAppCatalog.match(bundleID: "com.google.chrome") == nil)
    }

    // MARK: - Attribution order

    @Test func nativeMeetingAppsOutrankBrowsersForAttribution() {
        // With several catalogued processes capturing, the island names the
        // first catalog match — so a Zoom call in front of an open browser is
        // attributed to Zoom, not to Chrome.
        let zoomIndex = CallAppCatalog.apps.firstIndex { $0.displayName == "Zoom" }
        let chromeIndex = CallAppCatalog.apps.firstIndex { $0.displayName == "Google Chrome" }
        #expect(zoomIndex != nil)
        #expect(chromeIndex != nil)
        #expect(zoomIndex! < chromeIndex!)
    }
}
