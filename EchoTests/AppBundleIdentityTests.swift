//
//  AppBundleIdentityTests.swift
//  EchoTests
//
//  The path walk that makes browser detection browser-agnostic: a capturing
//  process's executable path, resolved to the outermost `.app` that contains
//  it. Real paths, taken from processes measured on this machine — the two
//  browser architectures (Chromium's `Helpers/…app`, Gecko's nested
//  `plugin-container.app`), the Electron apps that must NOT be read as
//  browsers, and the daemons and framework XPC services that belong to no app
//  at all.
//

import Testing
@testable import Echo

struct AppBundleIdentityTests {

    private func outermost(_ path: String) -> String? {
        AppBundleIdentity.outermostAppBundlePath(forExecutablePath: path)
    }

    // MARK: - Browser architectures

    @Test func chromiumHelpersResolveToTheBrowserBundle() {
        // Measured: Brave's renderer helper, nested three bundles deep inside
        // the framework. This one would also match on bundle ID alone
        // (`com.brave.Browser.helper.renderer`) — the path just has to agree.
        #expect(
            outermost("""
            /Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework\
            /Versions/151.1.93.138/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS\
            /Brave Browser Helper (Renderer)
            """) == "/Applications/Brave Browser.app"
        )
    }

    @Test func geckoMediaProcessesResolveToTheBrowserBundle() {
        // The case bundle IDs cannot solve: Zen's media process is
        // `app.zen-browser.plugincontainer`, which shares no prefix with the
        // browser's own `app.zen-browser.zen`. Its path does.
        #expect(
            outermost(
                "/Applications/Zen.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container"
            ) == "/Applications/Zen.app"
        )
    }

    @Test func aBrowsersOwnProcessResolvesToItself() {
        #expect(
            outermost("/Applications/Brave Browser.app/Contents/MacOS/Brave Browser")
                == "/Applications/Brave Browser.app"
        )
        // Safari lives inside the OS's sealed cryptex; the walk is agnostic
        // about where the bundle sits.
        #expect(
            outermost("""
            /System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari
            """) == "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"
        )
    }

    // MARK: - Not browsers

    @Test func electronHelpersResolveToTheirOwnApp() {
        // Electron apps spawn byte-identical Chromium helpers. Resolving to
        // the *outermost* app is what keeps them out of the browser tier: VS
        // Code is not an https handler, so this identity matches nothing.
        #expect(
            outermost("""
            /Applications/Visual Studio Code.app/Contents/Frameworks/Electron Framework.framework\
            /Helpers/chrome_crashpad_handler
            """) == "/Applications/Visual Studio Code.app"
        )
        // An app that nests a second copy of its own bundle still reports the
        // one the user launched.
        #expect(
            outermost("""
            /Users/Shared/Riot Games/Riot Client.app/Contents/Frameworks/Riot Client.app\
            /Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler
            """) == "/Users/Shared/Riot Games/Riot Client.app"
        )
    }

    @Test func processesOutsideAnyAppBundleResolveToNothing() {
        // Daemons: no app, therefore no identity — the silence that keeps a
        // nameless capture from ever being read as a call.
        #expect(outermost("/usr/sbin/mDNSResponderHelper") == nil)
        #expect(outermost("/usr/libexec/logd_helper") == nil)
        // A framework's XPC service is not inside an app either — which is
        // exactly why Safari's WebKit GPU process keeps its curated catalog
        // entry.
        #expect(
            outermost("""
            /System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices\
            /com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU
            """) == nil
        )
        #expect(outermost("") == nil)
    }

    // MARK: - Live resolution

    @Test func thisProcessResolvesToARealBundleOrNothingAtAll() {
        // The one non-pure path, kept honest without pinning it to a test
        // host's layout: whatever it returns for our own pid, it is either a
        // usable bundle ID or the empty string — never a half-resolved value.
        let resolved = AppBundleIdentity.appBundleID(ofPID: ProcessInfo.processInfo.processIdentifier)
        #expect(resolved.isEmpty || resolved.contains("."))
    }

    @Test func anUnusablePIDResolvesToNothing() {
        #expect(AppBundleIdentity.appBundleID(ofPID: -1).isEmpty)
    }
}
