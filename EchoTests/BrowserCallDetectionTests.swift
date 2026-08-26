//
//  BrowserCallDetectionTests.swift
//  EchoTests
//
//  Browser-agnostic detection: a Google Meet call is detected in whatever
//  browser the user runs it in, not only the six the curated catalog happened
//  to name. The browser tier is whatever LaunchServices says can open `https`
//  (`BrowserCatalog`), and a process is attributed to it through the app
//  bundle its executable lives in (`AppBundleIdentity`).
//
//  These tables pin the promise on both sides: an uncatalogued browser is
//  detected and can be silenced like any other app, while the curated tier
//  still wins where it speaks — and nothing that merely *looks* like a browser
//  process gets in.
//

import CoreAudio
import Testing
@testable import Echo

struct BrowserCallDetectionTests {

    /// Two real uncatalogued browsers, as `BrowserCatalog` would report them
    /// (name = bundle file name, so it is the same string on every Mac).
    private let zen = CallApp(displayName: "Zen", bundlePrefix: "app.zen-browser.zen")
    private let vivaldi = CallApp(displayName: "Vivaldi", bundlePrefix: "com.vivaldi.Vivaldi")
    private var installed: [CallApp] { [zen, vivaldi] }

    // MARK: - The gap this closes

    @Test func anUncataloguedBrowserIsDetectedThroughItsAppBundle() {
        // Zen's media process, the one that opens the mic for a Meet call. Its
        // own bundle ID shares no prefix with the browser (Gecko), so the app
        // bundle is the only identity that can attribute it.
        let matched = CallAppCatalog.match(
            bundleID: "app.zen-browser.plugincontainer",
            appBundleID: "app.zen-browser.zen",
            browsers: installed
        )
        #expect(matched?.displayName == "Zen")
        #expect(matched?.scopeable == true)
    }

    @Test func anUncataloguedBrowsersOwnProcessIsDetected() {
        #expect(
            CallAppCatalog.match(
                bundleID: "app.zen-browser.zen",
                appBundleID: "app.zen-browser.zen",
                browsers: installed
            )?.displayName == "Zen"
        )
    }

    @Test func aBrowserThatIsNotInstalledIsNotDetected() {
        // The tier is the machine's truth, not a second hardcoded list: with
        // Zen absent from the installed set, nothing matches it.
        #expect(
            CallAppCatalog.match(
                bundleID: "app.zen-browser.plugincontainer",
                appBundleID: "app.zen-browser.zen",
                browsers: [vivaldi]
            ) == nil
        )
    }

    /// The same bug the curated catalog had all along: Firefox's media process
    /// is `org.mozilla.plugincontainer`, which never matched the catalogued
    /// `org.mozilla.firefox`. The app bundle fixes the curated entry too, with
    /// no browser tier involved.
    @Test func firefoxsMediaProcessNowAttributesToTheCataloguedEntry() {
        #expect(CallAppCatalog.match(bundleID: "org.mozilla.plugincontainer") == nil)
        #expect(
            CallAppCatalog.match(
                bundleID: "org.mozilla.plugincontainer",
                appBundleID: "org.mozilla.firefox"
            )?.displayName == "Firefox"
        )
    }

    // MARK: - The curated tier still wins

    @Test func aCataloguedBrowserResolvesToItsCuratedEntry() {
        // Chrome is in both tiers. The curated entry answers, so Echo's
        // long-standing display names never drift to the bundle file name
        // ("Brave", not "Brave Browser").
        let chromeFromBoth = CallAppCatalog.match(
            bundleID: "com.google.Chrome.helper.renderer",
            appBundleID: "com.google.Chrome",
            browsers: [CallApp(displayName: "Google Chrome", bundlePrefix: "com.google.Chrome")]
        )
        #expect(chromeFromBoth?.displayName == "Google Chrome")

        let braveFromBoth = CallAppCatalog.match(
            bundleID: "com.brave.Browser.helper",
            appBundleID: "com.brave.Browser",
            browsers: [CallApp(displayName: "Brave Browser", bundlePrefix: "com.brave.Browser")]
        )
        #expect(braveFromBoth?.displayName == "Brave")
    }

    @Test func safarisGPUProcessStillMatchesWithNoAppBundleAtAll() {
        // WebKit's GPU process lives inside a framework, not an app, so its
        // app identity is empty — the curated entry is the only thing that can
        // name it, which is why it stays.
        #expect(
            CallAppCatalog.match(bundleID: "com.apple.WebKit.GPU", appBundleID: "")?.displayName
                == "Safari"
        )
    }

    // MARK: - What must not get in

    @Test func anElectronAppsChromiumHelpersAreNotABrowser() {
        // VS Code spawns byte-identical Chromium helper processes and is not
        // an https handler, so neither identity can match.
        #expect(
            CallAppCatalog.match(
                bundleID: "com.microsoft.VSCode.helper.renderer",
                appBundleID: "com.microsoft.VSCode",
                browsers: installed
            ) == nil
        )
    }

    @Test func aNamelessProcessInsideNoAppNeverMatches() {
        #expect(CallAppCatalog.match(bundleID: "", appBundleID: "", browsers: installed) == nil)
    }

    @Test func dictationIsStillInvisibleWithTheBrowserTierPresent() {
        // The false-positive containment the feature rests on, re-checked with
        // the new tier in play: it widens browsers, nothing else.
        #expect(CallAppCatalog.match(bundleID: "com.apple.assistantd", browsers: installed) == nil)
        #expect(CallAppCatalog.match(bundleID: "com.apple.VoiceMemos", browsers: installed) == nil)
        #expect(CallAppCatalog.match(bundleID: "com.apple.replayd", browsers: installed) == nil)
    }

    // MARK: - Attribution and the per-app filter

    @Test func nativeMeetingAppsAreStillAttributedBeforeBrowsers() {
        // A Zoom call in front of an open Meet tab is a Zoom call.
        let clients = [
            MicActivityMonitor.Client(
                pid: 100,
                bundleID: "app.zen-browser.plugincontainer",
                appBundleID: "app.zen-browser.zen"
            ),
            MicActivityMonitor.Client(pid: 101, bundleID: "us.zoom.xos", appBundleID: "us.zoom.xos"),
        ]
        let apps = CallDetectionController.matchedApps(from: clients, browsers: installed)
        #expect(apps.map(\.displayName) == ["Zoom", "Zen"])
    }

    @Test func anUncataloguedBrowserCanBeSilencedByName() {
        // Its Settings checkbox has to work like every other app's.
        let clients = [
            MicActivityMonitor.Client(
                pid: 100,
                bundleID: "app.zen-browser.plugincontainer",
                appBundleID: "app.zen-browser.zen"
            ),
        ]
        #expect(
            CallDetectionController.matchedApps(
                from: clients,
                disabledNames: ["Zen"],
                browsers: installed
            ).isEmpty
        )
    }

    @Test func aBrowserInBothTiersIsNeverListedTwice() {
        let clients = [
            MicActivityMonitor.Client(
                pid: 100,
                bundleID: "com.google.Chrome.helper",
                appBundleID: "com.google.Chrome"
            ),
        ]
        let apps = CallDetectionController.matchedApps(
            from: clients,
            browsers: [CallApp(displayName: "Google Chrome", bundlePrefix: "com.google.Chrome")]
        )
        #expect(apps.map(\.displayName) == ["Google Chrome"])
    }

    // MARK: - Settings rows

    @Test func settingsRowsCoverTheCuratedCatalogAndEveryInstalledBrowser() {
        let names = CallAppCatalog.detectableDisplayNames(browsers: installed)
        #expect(names.count == Set(names).count)
        #expect(names.first == "Zoom")            // curated order preserved
        #expect(names.contains("Zen"))
        #expect(names.contains("Vivaldi"))
        // An installed browser the curated table already names gets no second
        // row.
        let withChrome = CallAppCatalog.detectableDisplayNames(
            browsers: [CallApp(displayName: "Google Chrome", bundlePrefix: "com.google.Chrome")]
        )
        #expect(withChrome.filter { $0 == "Google Chrome" }.count == 1)
    }

    // MARK: - Scoped capture (SP-008) rides the same identity

    @Test func aGeckoBrowsersMediaProcessJoinsItsScopedTap() {
        // Detection and scoping must never disagree about what an app is: the
        // process the island attributed to Zen is the process its scoped tap
        // includes.
        let processes: [ScopedProcessResolution.ProcessEntry] = [
            .init(object: 10, bundleID: "app.zen-browser.zen", appBundleID: "app.zen-browser.zen"),
            .init(
                object: 11,
                bundleID: "app.zen-browser.plugincontainer",
                appBundleID: "app.zen-browser.zen"
            ),
            .init(object: 12, bundleID: "com.spotify.client", appBundleID: "com.spotify.client"),
        ]
        #expect(ScopedProcessResolution.includeSet(for: zen, in: processes) == [10, 11])
    }

    @Test func aDifferentAppsProcessesNeverJoinAScopedTap() {
        let processes: [ScopedProcessResolution.ProcessEntry] = [
            .init(
                object: 20,
                bundleID: "com.vivaldi.Vivaldi.helper",
                appBundleID: "com.vivaldi.Vivaldi"
            ),
        ]
        #expect(ScopedProcessResolution.includeSet(for: zen, in: processes).isEmpty)
    }

    // MARK: - The live tier

    @Test func theInstalledBrowserTierIsReadFromTheSystem() {
        // Not a table: whatever this Mac has. Safari ships with macOS, so it is
        // the one entry that must always be there, and names must be the bundle
        // file name — never "Safari.app", which the disabled-apps setting could
        // not match.
        let browsers = BrowserCatalog.installed()
        #expect(browsers.contains { $0.bundlePrefix == "com.apple.Safari" })
        #expect(browsers.allSatisfy { !$0.displayName.hasSuffix(".app") })
        #expect(browsers.allSatisfy { !$0.displayName.isEmpty && !$0.bundlePrefix.isEmpty })
        // Deduplicated: a browser shipping a second copy of its own bundle (an
        // updater) is one entry.
        #expect(browsers.map(\.bundlePrefix).count == Set(browsers.map(\.bundlePrefix)).count)
        // Every entry is scopeable — a browser's own processes are what play
        // the call's audio.
        #expect(browsers.allSatisfy { $0.scopeable })
    }
}
