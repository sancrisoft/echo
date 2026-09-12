//
//  CallDetectorTests.swift
//  CallDetectionTests
//
//  What the orchestrator adds on top of the machine's table: the filter runs
//  at one call site with the live settings, the monitor exists only while the
//  setting is on, the countdown publishes a real deadline, and "Meeting saved"
//  is only shown once the stop has persisted.
//
//  The timers are a seam rather than real sleeps — the tests assert which one
//  was armed and for how long, and fire it by hand. What firing then MEANS is
//  the machine's own table, tested next door.
//

import Audio
import EchoCore
import EchoCoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import CallDetection

@Suite("Call detection — the detector")
@MainActor
struct CallDetectorTests {

    // MARK: - Fakes

    /// Records start/stop and holds the callback so a test can push a report.
    private final class FakeMonitor: MicActivityWatching, @unchecked Sendable {
        let onClientsChanged: @MainActor ([MicCaptureClient]) -> Void
        private(set) var startCount = 0
        private(set) var stopCount = 0
        var isRunning: Bool { startCount > stopCount }

        init(onClientsChanged: @escaping @MainActor ([MicCaptureClient]) -> Void) {
            self.onClientsChanged = onClientsChanged
        }

        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
    }

    /// One armed timer: how long it was armed for, and the way to fire it.
    /// A fired timer leaves the live set for the same reason a cancelled one
    /// does — a one-shot timer is spent either way.
    private final class ArmedTimer {
        let seconds: TimeInterval
        private let fire: @MainActor () -> Void
        private(set) var isSpent = false

        init(seconds: TimeInterval, fire: @escaping @MainActor () -> Void) {
            self.seconds = seconds
            self.fire = fire
        }

        func cancel() { isSpent = true }

        @MainActor func expire() {
            isSpent = true
            fire()
        }
    }

    private final class TimerLog {
        private(set) var armed: [ArmedTimer] = []
        var live: [ArmedTimer] { armed.filter { !$0.isSpent } }

        func arm(_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> ArmedTimer {
            let timer = ArmedTimer(seconds: seconds, fire: fire)
            armed.append(timer)
            return timer
        }

        /// Expires the single live timer, failing loudly rather than trapping
        /// when a test's assumption about what is armed is wrong.
        @MainActor func expireOnlyTimer(
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws {
            let live = live
            try #require(
                live.count == 1, "expected exactly one armed timer, got \(live.count)",
                sourceLocation: sourceLocation)
            live[0].expire()
        }
    }

    /// The three verbs detection asks for, recorded. Filled after the detector
    /// exists, so a request can look at what it published.
    private final class RequestLog {
        var startedScopes: [CaptureScope] = []
        var stopCount = 0
        var openCount = 0
        /// Runs inside the stop, before it returns — where a test checks that
        /// the saved face has not been shown yet.
        var duringStop: (@MainActor () -> Void)?
    }

    // MARK: - Harness

    @MainActor
    private struct Harness {
        let detector: CallDetector
        let settings: AppSettings
        let timers: TimerLog
        let requests: RequestLog
        let monitor: () -> FakeMonitor?
        let directory: TemporaryDirectory

        func report(_ clients: [MicCaptureClient]) {
            monitor()?.onClientsChanged(clients)
        }
    }

    private static let zoom = ProcessSelector(displayName: "Zoom", bundlePrefix: "us.zoom.xos")
    private static let zen = ProcessSelector(displayName: "Zen", bundlePrefix: "app.zen-browser.zen")

    private func client(
        _ bundleID: String, appBundleID: String = "", pid: pid_t = 100
    )
        -> MicCaptureClient
    {
        MicCaptureClient(pid: pid, bundleID: bundleID, appBundleID: appBundleID)
    }

    private func makeHarness(browsers: [ProcessSelector] = []) throws -> Harness {
        let directory = try TemporaryDirectory(prefix: "echo-detector")
        let settings = AppSettings(fileURL: directory.path("settings.json"))
        let timers = TimerLog()
        let requests = RequestLog()
        let monitorBox = MonitorBox()

        let detector = CallDetector(
            settings: settings,
            requests: CallDetectionRequests(
                startRecording: { requests.startedScopes.append($0) },
                stopRecording: {
                    requests.stopCount += 1
                    requests.duringStop?()
                },
                openSavedMeeting: { requests.openCount += 1 }
            ),
            makeMonitor: { onChange in
                let monitor = FakeMonitor(onClientsChanged: onChange)
                monitorBox.monitor = monitor
                return monitor
            },
            installedBrowsers: { browsers },
            armTimer: { seconds, fire in
                let timer = timers.arm(seconds, fire)
                return { timer.cancel() }
            }
        )
        detector.start()
        return Harness(
            detector: detector,
            settings: settings,
            timers: timers,
            requests: requests,
            monitor: { monitorBox.monitor },
            directory: directory
        )
    }

    /// The monitor is built inside the detector's own initializer, so the
    /// factory hands it back through this.
    private final class MonitorBox {
        var monitor: FakeMonitor?
    }

    // MARK: - The filter runs once, with the live settings

    @Test func aReportIsMatchedThroughTheCatalogAndMirrored() throws {
        let harness = try makeHarness()
        defer { harness.directory.remove() }

        harness.report([client("us.zoom.xos"), client("com.apple.VoiceMemos", pid: 101)])

        #expect(harness.detector.appsInCall == [Self.zoom])
        #expect(harness.timers.live.map(\.seconds) == [CallDetectionTiming.startDebounce])
        #expect(harness.detector.face == nil, "nothing is shown before the debounce elapses")
    }

    @Test func theInstalledBrowserTierReachesTheMatcher() throws {
        let harness = try makeHarness(browsers: [Self.zen])
        defer { harness.directory.remove() }

        harness.report([client("app.zen-browser.plugincontainer", appBundleID: "app.zen-browser.zen")])

        #expect(harness.detector.appsInCall == [Self.zen])
    }

    @Test func aDisabledAppNeverReachesTheMachine() throws {
        let harness = try makeHarness()
        defer { harness.directory.remove() }
        harness.settings.setCallApp("Zoom", enabled: false)

        harness.report([client("us.zoom.xos")])

        #expect(harness.detector.appsInCall.isEmpty)
        #expect(harness.timers.live.isEmpty, "no debounce for an app nobody is watching")
    }

    @Test func disablingAnAppMidCallRetractsItsIslandWithNoCoreAudioEvent() throws {
        let harness = try makeHarness()
        defer { harness.directory.remove() }
        harness.report([client("us.zoom.xos")])
        try harness.timers.expireOnlyTimer()
        #expect(harness.detector.face == .startPrompt(appName: "Zoom", scoped: true))

        harness.settings.setCallApp("Zoom", enabled: false)
        harness.detector.settingsChanged()

        #expect(harness.detector.appsInCall.isEmpty)
        #expect(harness.detector.face == nil)
    }

    // MARK: - Off means off

    @Test func theMonitorRunsOnlyWhileTheSettingIsOn() throws {
        let harness = try makeHarness()
        defer { harness.directory.remove() }
        #expect(harness.monitor()?.isRunning == true)

        harness.report([client("us.zoom.xos")])
        harness.settings.setCallDetection(enabled: false)
        harness.detector.settingsChanged()

        #expect(harness.monitor()?.isRunning == false)
        #expect(harness.detector.appsInCall.isEmpty, "a stopped monitor watches nobody")
        #expect(harness.detector.face == nil)
        #expect(harness.timers.live.isEmpty)

        harness.settings.setCallDetection(enabled: true)
        harness.detector.settingsChanged()
        #expect(harness.monitor()?.isRunning == true)
    }

    @Test func aDetectorStartedWithTheSettingOffNeverStartsTheMonitor() throws {
        let directory = try TemporaryDirectory(prefix: "echo-detector")
        defer { directory.remove() }
        let settings = AppSettings(fileURL: directory.path("settings.json"))
        settings.setCallDetection(enabled: false)
        let box = MonitorBox()

        let detector = CallDetector(
            settings: settings,
            requests: CallDetectionRequests(
                startRecording: { _ in },
                stopRecording: {},
                openSavedMeeting: {}
            ),
            makeMonitor: { onChange in
                let monitor = FakeMonitor(onClientsChanged: onChange)
                box.monitor = monitor
                return monitor
            },
            installedBrowsers: { [] },
            armTimer: { _, _ in {} }
        )
        detector.start()

        #expect(box.monitor?.startCount == 0)
    }

    @Test func theSettingIsFollowedWithoutBeingPolled() async throws {
        let harness = try makeHarness()
        defer { harness.directory.remove() }
        harness.report([client("us.zoom.xos")])
        #expect(harness.monitor()?.isRunning == true)

        harness.settings.setCallDetection(enabled: false)

        // The observation lands on a later main-actor turn: `onChange` fires
        // before the new value does, so the detector reads it from a Task.
        for _ in 0..<10 where harness.monitor()?.isRunning == true {
            await Task.yield()
        }
        #expect(harness.monitor()?.isRunning == false)
    }

    // MARK: - Timers

    @Test func eachTimerIsArmedForItsMeasuredInterval() throws {
        let harness = try makeHarness()
        defer { harness.directory.remove() }

        harness.report([client("us.zoom.xos")])
        #expect(harness.timers.live.map(\.seconds) == [CallDetectionTiming.startDebounce])

        try harness.timers.expireOnlyTimer()
        #expect(harness.timers.live.map(\.seconds) == [CallDetectionTiming.retract])

        try harness.timers.expireOnlyTimer()
        #expect(harness.detector.face == .compactPill)
        #expect(harness.timers.live.isEmpty, "a retracted prompt arms nothing further")
    }

    @Test func thePointerOnTheIslandDisarmsTheRetractAndLeavingRearmsIt() throws {
        // The seam the island reaches down through: it reports the fact, the
        // machine decides what it means, and the detector is where that shows
        // up as a real timer being cancelled and armed again.
        let harness = try makeHarness()
        defer { harness.directory.remove() }

        harness.report([client("us.zoom.xos")])
        try harness.timers.expireOnlyTimer()  // the debounce
        #expect(harness.timers.live.map(\.seconds) == [CallDetectionTiming.retract])

        harness.detector.hoverChanged(true)
        #expect(harness.timers.live.isEmpty, "the retract ran on under the pointer")

        harness.detector.hoverChanged(false)
        #expect(harness.timers.live.map(\.seconds) == [CallDetectionTiming.retract])

        try harness.timers.expireOnlyTimer()
        #expect(harness.detector.face == .compactPill)
    }

    @Test func aBlipInsideTheDebounceCancelsItsTimer() throws {
        let harness = try makeHarness()
        defer { harness.directory.remove() }
        harness.report([client("us.zoom.xos")])

        harness.report([])

        #expect(harness.timers.live.isEmpty)
        #expect(harness.detector.face == nil)
    }

    @Test func theCountdownPublishesTheRealDeadline() throws {
        let harness = try makeHarness()
        defer { harness.directory.remove() }
        harness.detector.recordingChanged(true)
        harness.report([client("us.zoom.xos")])
        try harness.timers.expireOnlyTimer()

        let before = Date()
        harness.report([])
        let after = Date()

        // The face renders its countdown from this, so it has to be the real
        // deadline of the timer that was just armed — not a second clock.
        let deadline = try #require(harness.detector.graceDeadline)
        #expect(deadline >= before.addingTimeInterval(CallDetectionTiming.endGrace))
        #expect(deadline <= after.addingTimeInterval(CallDetectionTiming.endGrace))
        #expect(harness.detector.face == .endGrace(appName: "Zoom"))
    }

    @Test func aReconnectInsideTheGraceClearsTheDeadlineAndCancelsTheStop() throws {
        let harness = try makeHarness()
        defer { harness.directory.remove() }
        harness.detector.recordingChanged(true)
        harness.report([client("us.zoom.xos")])
        try harness.timers.expireOnlyTimer()
        harness.report([])
        #expect(harness.detector.graceDeadline != nil)

        harness.report([client("us.zoom.xos")])

        #expect(harness.detector.graceDeadline == nil)
        #expect(harness.timers.live.isEmpty)
        #expect(harness.requests.stopCount == 0)
        #expect(harness.detector.face == nil)
    }

    // MARK: - The requests

    @Test func aStartTapRequestsTheScopeTheIslandNamed() throws {
        let harness = try makeHarness()
        defer { harness.directory.remove() }
        harness.report([client("us.zoom.xos")])
        try harness.timers.expireOnlyTimer()

        harness.detector.startTapped()

        #expect(harness.requests.startedScopes == [.app(Self.zoom)])
        #expect(harness.detector.face == nil)
    }

    @Test func theSavedFaceIsShownOnlyOnceTheStopHasPersisted() async throws {
        let harness = try makeHarness()
        defer { harness.directory.remove() }
        harness.detector.recordingChanged(true)
        harness.report([client("us.zoom.xos")])
        try harness.timers.expireOnlyTimer()
        harness.report([])

        var faceDuringStop: IslandFace??
        harness.requests.duringStop = { faceDuringStop = .some(harness.detector.face) }
        harness.detector.stopNowTapped()

        // The stop request suspends; the deferred actions land after it.
        for _ in 0..<10 where harness.detector.face != .saved {
            await Task.yield()
        }
        #expect(harness.requests.stopCount == 1)
        #expect(
            faceDuringStop == .some(.endGrace(appName: "Zoom")),
            "the island claimed a saved meeting before the meeting was persisted"
        )
        #expect(harness.detector.face == .saved)
        // The countdown's deadline is gone the moment its timer is cancelled,
        // so the face outlives its number for as long as the stop takes. The
        // panel renders a countdown-less end-grace face there, as in the PoC.
        #expect(harness.detector.graceDeadline == nil)
    }

    @Test func openingTheSavedMeetingAsksTheSurfaceAbove() async throws {
        let harness = try makeHarness()
        defer { harness.directory.remove() }
        harness.detector.recordingChanged(true)
        harness.report([client("us.zoom.xos")])
        try harness.timers.expireOnlyTimer()
        harness.report([])
        harness.detector.stopNowTapped()
        for _ in 0..<10 where harness.detector.face != .saved {
            await Task.yield()
        }

        harness.detector.openEchoTapped()

        #expect(harness.requests.openCount == 1)
        #expect(harness.detector.face == nil)
    }

    @Test func nothingIsRequestedWithoutATap() throws {
        let harness = try makeHarness()
        defer { harness.directory.remove() }

        harness.report([client("us.zoom.xos")])
        try harness.timers.expireOnlyTimer()
        try harness.timers.expireOnlyTimer()
        harness.report([])

        #expect(harness.requests.startedScopes.isEmpty)
        #expect(harness.requests.stopCount == 0)
    }

    // MARK: - Teardown

    @Test func stoppingLeavesNoListenerNoTimerAndNoFace() throws {
        let harness = try makeHarness()
        defer { harness.directory.remove() }
        harness.report([client("us.zoom.xos")])
        try harness.timers.expireOnlyTimer()

        harness.detector.stop()

        #expect(harness.monitor()?.isRunning == false)
        #expect(harness.timers.live.isEmpty)
        #expect(harness.detector.face == nil)
        #expect(harness.detector.appsInCall.isEmpty)
    }
}
