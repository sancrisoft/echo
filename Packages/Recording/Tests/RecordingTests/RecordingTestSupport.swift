//
//  RecordingTestSupport.swift
//  RecordingTests
//
//  The fakes behind `CaptureFactories`, and the harness that stands a real
//  `RecordingSession` up over a temporary data folder.
//
//  No test here may open a microphone or a process tap, so every capture the
//  session builds is a fake that records what it was asked to do and hands
//  the test the callbacks it was constructed with. That is the whole reason
//  `MicCapturing` / `SystemCapturing` exist (see `CaptureSeams`), and it is
//  why the fakes take their scripts as closures: both real sources take their
//  callbacks at `init`, so a session builds its sources and can never
//  reconfigure one afterwards.
//
//  State is `Mutex`-guarded rather than isolated, like `CollectingGateSink`
//  in AudioTests: the session invokes these from the main actor while the
//  test reads them from wherever it happens to be, and the seam's contract is
//  `Sendable`, not an isolation domain.
//

import Audio
import CoreAudio
import EchoCore
import EchoCoreTestSupport
import Foundation
import Meetings
import Summarization
import Synchronization
import Testing

@testable import Recording

// MARK: - Scripted failures

/// An arbitrary, non-degradable capture failure — anything that is not
/// `MicrophoneCapture.CaptureError.noInputDevice`, which the session treats
/// specially.
struct ScriptedCaptureFailure: Error, Equatable {
    let reason: String
}

// MARK: - Capture fakes

/// The microphone seam. `start()` consults the script with its attempt
/// number, so a test can fail the first bring-up and let a rebuild succeed.
final class FakeMicCapture: MicCapturing {

    private struct Calls {
        var starts = 0
        var stops = 0
    }

    private let calls = Mutex(Calls())
    private let onSamples: @Sendable ([Float]) -> Void
    private let onLevel: @Sendable (Double) -> Void
    private let startOutcome: @Sendable (Int) throws -> Void

    init(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onLevel: @escaping @Sendable (Double) -> Void,
        startOutcome: @escaping @Sendable (Int) throws -> Void
    ) {
        self.onSamples = onSamples
        self.onLevel = onLevel
        self.startOutcome = startOutcome
    }

    func start() async throws {
        let attempt = calls.withLock { calls -> Int in
            calls.starts += 1
            return calls.starts
        }
        try startOutcome(attempt)
    }

    func stop() {
        calls.withLock { $0.stops += 1 }
    }

    var starts: Int { calls.withLock { $0.starts } }
    var stops: Int { calls.withLock { $0.stops } }

    /// Delivers one batch the way the render thread would.
    func emit(samples: [Float]) { onSamples(samples) }

    /// Delivers one un-averaged meter reading.
    func emit(level: Double) { onLevel(level) }
}

/// The system-audio seam. It keeps every scope it was started with, because
/// what a session establishes — global, scoped, or a global fallback after a
/// scoped failure — is only visible in the scopes the taps were handed.
final class FakeSystemCapture: SystemCapturing {

    private struct Calls {
        var startedScopes: [CaptureScope] = []
        var stops = 0
    }

    private let calls = Mutex(Calls())
    private let onSamples: @Sendable ([Float]) -> Void
    private let onLevel: (@Sendable (Double) -> Void)?
    private let startOutcome: @Sendable () throws -> Void

    /// Whether the session built this tap with a level callback. The
    /// reference tap a scoped session runs must not have one — nothing from
    /// it is ever metered — so this is the only way to tell the two apart.
    let isMetered: Bool

    init(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onLevel: (@Sendable (Double) -> Void)?,
        startOutcome: @escaping @Sendable () throws -> Void
    ) {
        self.onSamples = onSamples
        self.onLevel = onLevel
        self.startOutcome = startOutcome
        self.isMetered = onLevel != nil
    }

    func start(scope: CaptureScope) throws {
        // Recorded before the script runs: a test asserting on the fallback
        // has to see the scope the failed attempt asked for.
        calls.withLock { $0.startedScopes.append(scope) }
        try startOutcome()
    }

    func stop() {
        calls.withLock { $0.stops += 1 }
    }

    var startedScopes: [CaptureScope] { calls.withLock { $0.startedScopes } }
    var startedScope: CaptureScope? { startedScopes.first }
    var stops: Int { calls.withLock { $0.stops } }

    func emit(samples: [Float]) { onSamples(samples) }
    func emit(level: Double) { onLevel?(level) }
}

/// An inert default-input watcher: it reports one scripted device forever and
/// arms no Core Audio listener. Device events reach the session through
/// `handleInputDeviceEvent`, which exists for exactly that.
final class FakeInputDeviceWatcher: InputDeviceWatching {

    private struct Calls {
        var starts = 0
        var stops = 0
    }

    private let calls = Mutex(Calls())
    private let device: InputDeviceLifecycleMachine.DeviceID?

    init(device: InputDeviceLifecycleMachine.DeviceID?) {
        self.device = device
    }

    func currentDefaultInputDevice() -> InputDeviceLifecycleMachine.DeviceID? { device }
    func start() { calls.withLock { $0.starts += 1 } }
    func stop() { calls.withLock { $0.stops += 1 } }

    var starts: Int { calls.withLock { $0.starts } }
    var stops: Int { calls.withLock { $0.stops } }
}

/// An output-route watcher reporting one scripted route, which arms no Core
/// Audio listener but DOES keep the callbacks it was handed: the route decides
/// the session's echo-handling mode, and a mid-session route change is how the
/// degradation notice clears.
final class FakeOutputRouteWatcher: OutputRouteWatching {

    private struct Calls {
        var starts = 0
        var stops = 0
    }

    private let calls = Mutex(Calls())
    private let route: OutputRouteClass
    private let onRouteChange: @Sendable (OutputRouteClass) -> Void

    init(route: OutputRouteClass, onRouteChange: @escaping @Sendable (OutputRouteClass) -> Void) {
        self.route = route
        self.onRouteChange = onRouteChange
    }

    /// Reports a route change the way the real monitor would.
    func reportRouteChange(_ route: OutputRouteClass) { onRouteChange(route) }

    func currentRoute() -> OutputRouteClass { route }
    func start() { calls.withLock { $0.starts += 1 } }
    func stop() { calls.withLock { $0.stops += 1 } }

    var starts: Int { calls.withLock { $0.starts } }
    var stops: Int { calls.withLock { $0.stops } }
}

/// A pass-through AEC stage that counts what reached it — the only way to see
/// which tap a session wired to the far end — and that can report engine
/// health, which is the only way to reach the degradation notice.
final class CountingAECStage: EchoCancelling {

    private struct Calls {
        var micFrames = 0
        var farEndFrames = 0
        var resets = 0
        var healthy = true
        var handler: (@Sendable (Bool) -> Void)?
    }

    private let calls = Mutex(Calls())

    init(healthy: Bool = true) {
        calls.withLock { $0.healthy = healthy }
    }

    // MARK: EchoCancelling

    var isEngineHealthy: Bool { calls.withLock { $0.healthy } }

    func setEngineEventHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        calls.withLock { $0.handler = handler }
    }

    /// Reports a health transition the way the real engine would — and only a
    /// transition, which is the behaviour that makes a missed notice possible.
    func reportEngineHealth(_ healthy: Bool) {
        let handler = calls.withLock { state -> (@Sendable (Bool) -> Void)? in
            state.healthy = healthy
            return state.handler
        }
        handler?(healthy)
    }

    func processMicSamples(_ samples: [Float]) -> [Float] {
        calls.withLock { $0.micFrames += samples.count }
        return samples
    }

    func feedFarEnd(_ samples: [Float]) {
        calls.withLock { $0.farEndFrames += samples.count }
    }

    func reset() {
        calls.withLock { $0.resets += 1 }
    }

    var micFrames: Int { calls.withLock { $0.micFrames } }
    var farEndFrames: Int { calls.withLock { $0.farEndFrames } }
    var resets: Int { calls.withLock { $0.resets } }
}

// MARK: - The factories a test drives

/// Builds the fakes the session asks for and keeps every instance in creation
/// order. A scoped session builds up to three system taps — the reference,
/// the scoped one, and a global fallback when the scoped one fails — and the
/// order is the only evidence of which topology was established.
final class CaptureRig: Sendable {

    private struct Built {
        var microphones: [FakeMicCapture] = []
        var systemCaptures: [FakeSystemCapture] = []
        var inputWatchers: [FakeInputDeviceWatcher] = []
        var outputWatchers: [FakeOutputRouteWatcher] = []
    }

    private let built = Mutex(Built())

    /// Shared across sessions on purpose: a test that starts twice can still
    /// read one set of counts.
    let echoStage: CountingAECStage

    private let permissionPrimings = Mutex(0)

    /// How many times the session raised the permission dialogs. Once per app
    /// run, on the first record gesture — never at launch.
    var permissionPrimeCount: Int { permissionPrimings.withLock { $0 } }

    private let inputDevice: InputDeviceLifecycleMachine.DeviceID?
    private let route: OutputRouteClass
    private let micStartOutcome: @Sendable (Int) throws -> Void
    private let systemStartOutcome: @Sendable (Int) throws -> Void

    /// `systemStartOutcome` is keyed by the tap's CREATION index (1-based),
    /// not by its attempt count: the reference, the scoped tap and the
    /// fallback are three different objects, so "the scoped tap fails" can
    /// only be said about the second one built.
    init(
        inputDevice: InputDeviceLifecycleMachine.DeviceID? = 1,
        route: OutputRouteClass = .builtInSpeakers,
        engineHealthy: Bool = true,
        micStartOutcome: @escaping @Sendable (Int) throws -> Void = { _ in },
        systemStartOutcome: @escaping @Sendable (Int) throws -> Void = { _ in }
    ) {
        self.inputDevice = inputDevice
        self.route = route
        self.echoStage = CountingAECStage(healthy: engineHealthy)
        self.micStartOutcome = micStartOutcome
        self.systemStartOutcome = systemStartOutcome
    }

    func factories() -> CaptureFactories {
        CaptureFactories(
            makeMicrophone: { onSamples, onLevel in
                let capture = FakeMicCapture(
                    onSamples: onSamples, onLevel: onLevel, startOutcome: self.micStartOutcome)
                self.built.withLock { $0.microphones.append(capture) }
                return capture
            },
            makeSystem: { onSamples, onLevel in
                let index = self.built.withLock { $0.systemCaptures.count + 1 }
                let capture = FakeSystemCapture(onSamples: onSamples, onLevel: onLevel) {
                    try self.systemStartOutcome(index)
                }
                self.built.withLock { $0.systemCaptures.append(capture) }
                return capture
            },
            makeEchoCanceller: { self.echoStage },
            // No TCC prompt and no throwaway process tap: a package test runs
            // with no host, and the live primer would block on a dialog
            // nobody is there to answer.
            primePermissions: { self.permissionPrimings.withLock { $0 += 1 } },
            makeInputDeviceWatcher: { _ in
                let watcher = FakeInputDeviceWatcher(device: self.inputDevice)
                self.built.withLock { $0.inputWatchers.append(watcher) }
                return watcher
            },
            makeOutputRouteWatcher: { onRoute, _ in
                let watcher = FakeOutputRouteWatcher(route: self.route, onRouteChange: onRoute)
                self.built.withLock { $0.outputWatchers.append(watcher) }
                return watcher
            }
        )
    }

    var microphones: [FakeMicCapture] { built.withLock { $0.microphones } }
    var systemCaptures: [FakeSystemCapture] { built.withLock { $0.systemCaptures } }
    var inputWatchers: [FakeInputDeviceWatcher] { built.withLock { $0.inputWatchers } }
    var outputWatchers: [FakeOutputRouteWatcher] { built.withLock { $0.outputWatchers } }

    var microphone: FakeMicCapture? { microphones.first }
    var systemCapture: FakeSystemCapture? { systemCaptures.first }
    var outputWatcher: FakeOutputRouteWatcher? { outputWatchers.first }
}

// MARK: - The harness

/// A real `RecordingSession` over a real store, a real settings file and a
/// summary model that can neither download nor load, all under one temporary
/// directory.
@MainActor
struct SessionHarness {

    let temp: TemporaryDirectory
    let library: MeetingLibrary
    let settings: AppSettings
    let summaryModel: SummaryModel
    let rig: CaptureRig
    let session: RecordingSession

    var store: MeetingStore { library.store }
    var meetingsRoot: URL { temp.path("Meetings") }
    var stagingRoot: URL { store.retentionStagingDirectory }

    /// The meeting folders on disk. The retention staging tree is a sibling
    /// of them inside the same root, so it is excluded by name.
    func meetingFolders() -> [URL] {
        contents(of: meetingsRoot)
            .filter { $0.lastPathComponent != MeetingStore.retentionStagingDirectoryName }
    }

    /// The per-session staging folders that still exist.
    func stagedSessionFolders() -> [URL] {
        contents(of: stagingRoot)
    }

    func fileNames(in folder: URL) -> Set<String> {
        Set(contents(of: folder).map(\.lastPathComponent))
    }

    private func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil))
            ?? []
    }

    /// Emits one real batch on each channel and waits for the retention
    /// writer to have taken both.
    ///
    /// A stop only produces a meeting when there is audio to keep, and the
    /// writer encodes AAC through `AVAudioFile`, so the batches have to be
    /// real samples rather than a token. The ingest tap is the LAST system
    /// capture built: in a scoped session the first one is the AEC reference,
    /// whose audio is never persisted.
    func captureAudibleAudio() async throws {
        let mic = try #require(rig.microphones.first)
        let ingest = try #require(rig.systemCaptures.last)
        mic.emit(samples: audibleBatch())
        ingest.emit(samples: audibleBatch())

        await waitUntil("the retention writer to stage both channels") {
            fileNames(in: stagedSessionFolders().first ?? stagingRoot)
                .isSuperset(of: ["retained-mic.m4a", "retained-system.m4a"])
        }
    }
}

/// Stands a session up, runs `body`, and removes the temporary folder.
///
/// The summary model is built with every seam injected so the record-start
/// prefetch can neither reach the network nor put weights in RAM:
/// `snapshotExists` answers yes, which is where `ensureDownloaded` stops.
@MainActor
func withSession<T>(
    rig: CaptureRig = CaptureRig(),
    _ body: (SessionHarness) async throws -> T
) async throws -> T {
    let temp = try TemporaryDirectory(prefix: "RecordingSessionTests")
    defer { temp.remove() }

    let library = MeetingLibrary(store: MeetingStore(rootDirectory: temp.path("Meetings")))
    let settings = AppSettings(fileURL: temp.path("settings.json"))
    let summaryModel = SummaryModel(
        modelsRoot: temp.path("Models"),
        pauseStateFile: temp.path("summary-download.json"),
        loader: { _ in
            Issue.record("The session loaded the summary engine during a recording")
            throw ScriptedCaptureFailure(reason: "no engine is ever loaded in a unit test")
        },
        downloader: { _ in
            Issue.record("The session started a summary-model download during a recording")
        },
        snapshotExists: { true }
    )
    let session = RecordingSession(
        library: library,
        settings: settings,
        summaryModel: summaryModel,
        factories: rig.factories()
    )

    return try await body(
        SessionHarness(
            temp: temp,
            library: library,
            settings: settings,
            summaryModel: summaryModel,
            rig: rig,
            session: session
        )
    )
}

// MARK: - Waiting without a clock

/// Yields until `condition` holds, and fails the test if it never does.
///
/// The session hops off the capture callbacks — one task per ingest batch,
/// one per level reading — so a test has to let those land. Yielding rather
/// than sleeping, because a sleep is a wall-clock assertion in disguise: it
/// passes on a fast machine and flakes on a loaded one.
@MainActor
func waitUntil(
    _ description: String,
    limit: Int = 20_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    for _ in 0..<limit {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
}

/// A batch of audible samples: enough frames for the retention writer to
/// produce a real AAC file, and a shape no gate could mistake for silence.
func audibleBatch(frames: Int = 4_000, seed: Float = 0.4) -> [Float] {
    (0..<frames).map { index in
        seed * sin(Float(index) * 0.05)
    }
}
