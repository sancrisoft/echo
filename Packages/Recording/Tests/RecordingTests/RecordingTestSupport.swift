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
import Transcription

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
    let pass: ScriptedPass
    let summarizer: ScriptedSummarizer?
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
    pass: ScriptedPass = ScriptedPass(),
    summarizer: ScriptedSummarizer? = nil,
    summaryModelOnDisk: Bool = true,
    summaryEngineFailures: Int = 0,
    _ body: (SessionHarness) async throws -> T
) async throws -> T {
    let temp = try TemporaryDirectory(prefix: "RecordingSessionTests")
    defer { temp.remove() }

    // A scripted model-level failure, exhausted after `summaryEngineFailures`
    // loads so a test can also see what happens once the model comes back.
    let remainingEngineFailures = Mutex(summaryEngineFailures)

    let library = MeetingLibrary(store: MeetingStore(rootDirectory: temp.path("Meetings")))
    let settings = AppSettings(fileURL: temp.path("settings.json"))
    let summaryModel = SummaryModel(
        modelsRoot: temp.path("Models"),
        pauseStateFile: temp.path("summary-download.json"),
        loader: { _ in
            // Only a test that scripted the summarizer may hold an engine:
            // the scheduler acquires one before it generates, so the acquire
            // has to succeed there — and nowhere else, because putting real
            // weights in RAM is exactly what a unit test must never do.
            // The model itself is what went wrong, so no meeting may be
            // blamed for it.
            let shouldFail = remainingEngineFailures.withLock { remaining -> Bool in
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
            if shouldFail { throw SummaryModelError.loadFailed("the weights would not map") }
            guard summarizer != nil else {
                Issue.record("The session loaded the summary engine during a recording")
                throw ScriptedCaptureFailure(reason: "no engine is ever loaded in a unit test")
            }
            return InertTextEngine()
        },
        downloader: { _ in
            Issue.record("The session started a summary-model download during a recording")
        },
        snapshotExists: { summaryModelOnDisk }
    )
    // Present on disk and never fetched: a session must never wait for a
    // model, and a unit test must never download one.
    let transcriptionModel = ParakeetModel(
        modelsRoot: temp.path("Models"),
        modelsPresent: { true },
        downloader: { _ in
            Issue.record("The session downloaded the transcription model")
        }
    )
    let session = RecordingSession(
        library: library,
        settings: settings,
        summaryModel: summaryModel,
        transcriptionModel: transcriptionModel,
        runTranscriptionPass: { files, yield, progress in
            try await pass.run(retainedFiles: files, shouldYield: yield, onProgress: progress)
        },
        // Nil leaves the real `Summarizer` in place, which is what every
        // capture-level test wants: it can only be reached through an engine
        // the loader above refuses to hand out.
        generateSummary: summarizer?.generate,
        generateCaption: summarizer?.caption,
        factories: rig.factories()
    )

    return try await body(
        SessionHarness(
            temp: temp,
            library: library,
            settings: settings,
            summaryModel: summaryModel,
            rig: rig,
            pass: pass,
            summarizer: summarizer,
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

// MARK: - The transcription pass

/// A scripted stand-in for the Parakeet pass.
///
/// Outcomes are consumed in order, so "fails twice then succeeds" is one
/// array. The default is a single empty success, which is a legitimate
/// outcome — the model heard no speech — and keeps every layer-1 test from
/// needing to think about finalization at all.
final class ScriptedPass: Sendable {

    enum Outcome: Sendable {
        case segments([TranscriptSegment])
        case failure
        /// The pass observed the yield signal between decode windows.
        case preempted
        /// Reports progress, then observes whatever the yield signal says —
        /// the real pass's behaviour, so a test can start a recording
        /// mid-pass and see a deferral rather than a failure.
        case yieldingIfAsked([TranscriptSegment])
    }

    private struct State {
        var outcomes: [Outcome]
        var meetingCalls = 0
        var reportedProgress: [Double] = []
        var entered: Int = 0
        var release = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    init(_ outcomes: [Outcome] = [.segments([])]) {
        state = Mutex(State(outcomes: outcomes))
    }

    /// How many passes ran.
    var calls: Int { state.withLock { $0.meetingCalls } }
    /// How many passes are currently held at the gate below.
    var entered: Int { state.withLock { $0.entered } }

    /// Holds every pass until `releaseAll()`, so a test can act while one is
    /// decoding.
    ///
    /// A continuation gate rather than a polling loop: a pass a test never
    /// releases then simply stays suspended instead of spinning on
    /// `Task.yield()` past the end of the test — which, with the temporary
    /// directory already removed, is a busy loop nobody is waiting for.
    func holdPasses() { state.withLock { $0.release = false } }

    func releaseAll() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.release = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for continuation in waiting { continuation.resume() }
    }

    private func waitForRelease() async {
        await withCheckedContinuation { continuation in
            let released = state.withLock { state -> Bool in
                if state.release { return true }
                state.waiters.append(continuation)
                return false
            }
            if released { continuation.resume() }
        }
    }

    func run(
        retainedFiles: [AudioChannel: URL],
        shouldYield: @escaping @Sendable () -> Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        let outcome = state.withLock { state -> Outcome in
            state.meetingCalls += 1
            state.entered += 1
            return state.outcomes.isEmpty ? .failure : state.outcomes.removeFirst()
        }
        // Suspends until the test releases the gate; no clock and no
        // polling.
        await waitForRelease()
        state.withLock { $0.entered -= 1 }

        switch outcome {
        case .segments(let segments):
            onProgress(1)
            return segments
        case .failure:
            throw ScriptedCaptureFailure(reason: "the scripted pass failed")
        case .preempted:
            throw TranscriptionError.preempted
        case .yieldingIfAsked(let segments):
            onProgress(0.5)
            if shouldYield() { throw TranscriptionError.preempted }
            onProgress(1)
            return segments
        }
    }
}

// MARK: - Recording what a driver did

/// An append-only log of what happened, in the order it happened.
///
/// Ordering IS the assertion for most of the driver's rules — the summary
/// model is released before the first decode, a summary is granted only after
/// a pass ends — and a captured `var` cannot carry that out of an escaping
/// closure. `Mutex` rather than an actor for the reason the capture fakes use
/// one: the writer is the main actor and the reader is the test, and the
/// contract is `Sendable`, not an isolation domain.
final class OrderLog: Sendable {

    private let log = Mutex<[String]>([])

    func append(_ entry: String) { log.withLock { $0.append(entry) } }

    var entries: [String] { log.withLock { $0 } }
    var isEmpty: Bool { log.withLock { $0.isEmpty } }
}

/// Every snapshot a driver published, in order — the whole of what a surface
/// would have seen while it worked.
final class SnapshotLog: Sendable {

    private let log = Mutex<[FinalizationDriver.Snapshot]>([])

    func append(_ snapshot: FinalizationDriver.Snapshot) { log.withLock { $0.append(snapshot) } }

    var snapshots: [FinalizationDriver.Snapshot] { log.withLock { $0 } }
    var progressValues: [Double?] { snapshots.map(\.progress) }
}

/// Scripted pass results for the driver, consumed in order, recording every
/// meeting it was asked about. The shorter cousin of `ScriptedPass`, for the
/// driver tests that care about admission rather than about what a decode
/// does at its gate.
final class ScriptedRunner: Sendable {

    private struct State {
        var results: [FinalizationDriver.PassResult]
        var calledMeetingIDs: [UUID] = []
    }

    private let state: Mutex<State>

    init(_ results: [FinalizationDriver.PassResult]) {
        state = Mutex(State(results: results))
    }

    func run(_ id: UUID) -> FinalizationDriver.PassResult {
        state.withLock { state in
            state.calledMeetingIDs.append(id)
            return state.results.isEmpty ? .failed : state.results.removeFirst()
        }
    }

    var calledMeetingIDs: [UUID] { state.withLock { $0.calledMeetingIDs } }
}

/// Keeps the progress sink the driver hands each pass, so a test can report a
/// fraction whenever it likes — including from an attempt that has already
/// ended, which is the straggler the attempt scoping exists to reject.
final class ProgressSinks: Sendable {

    private let sinks = Mutex<[@Sendable (Double) -> Void]>([])

    /// Called from inside a `runPass` closure, once per attempt.
    func capture(_ sink: @escaping @Sendable (Double) -> Void) {
        sinks.withLock { $0.append(sink) }
    }

    var count: Int { sinks.withLock { $0.count } }

    /// Reports `fraction` through the sink of the given 1-based attempt.
    func report(_ fraction: Double, fromAttempt attempt: Int) {
        let sink = sinks.withLock { sinks -> (@Sendable (Double) -> Void)? in
            sinks.indices.contains(attempt - 1) ? sinks[attempt - 1] : nil
        }
        sink?(fraction)
    }
}

/// Holds every pass that reaches it until the test releases them, so a test
/// can act while one is decoding.
///
/// Continuation-based rather than yield-based, because a driver test needs to
/// know a pass has ARRIVED (`entered`) as well as to let it go: a spin loop
/// would let the pass finish before the test could act.
final class PassGate: Sendable {

    private struct State {
        var waiters: [CheckedContinuation<Void, Never>] = []
        var entered = 0
    }

    private let state = Mutex(State())

    /// How many passes have reached the gate over the gate's whole life —
    /// never decremented, so "the second attempt started" is `entered == 2`.
    var entered: Int { state.withLock { $0.entered } }

    func enter() async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                state.entered += 1
                state.waiters.append(continuation)
            }
        }
    }

    /// Releases everything waiting now. A pass that arrives afterwards waits
    /// again, which is what makes "release attempt 1, catch attempt 2"
    /// expressible.
    func releaseAll() {
        let released = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in released { waiter.resume() }
    }
}

/// Counts calls, so a scripted pass can answer differently per attempt
/// without capturing a `var`.
final class AttemptCounter: Sendable {

    private let count = Mutex(0)

    /// The 1-based number of this call.
    func next() -> Int {
        count.withLock { count in
            count += 1
            return count
        }
    }

    var value: Int { count.withLock { $0 } }
}

/// A `FinalizationDriver` with every seam defaulted to a no-op, so each test
/// scripts only the one it is about.
@MainActor
func makeDriver(
    runPass:
        @escaping @MainActor (
            UUID, @escaping @Sendable () -> Bool, @escaping @Sendable (Double) -> Void
        ) async -> FinalizationDriver.PassResult,
    prepareForPass: @escaping @MainActor () async -> Void = {},
    convergeTerminally: @escaping @MainActor (UUID) async -> Void = { _ in },
    onBackgroundPassConcluded:
        @escaping @MainActor (UUID, FinalizationDriver.PassResult) async ->
        Void = { _, _ in },
    onStateChanged: @escaping @MainActor (FinalizationDriver.Snapshot) -> Void = { _ in }
) -> FinalizationDriver {
    FinalizationDriver(
        runPass: runPass,
        prepareForPass: prepareForPass,
        convergeTerminally: convergeTerminally,
        onBackgroundPassConcluded: onBackgroundPassConcluded,
        onStateChanged: onStateChanged
    )
}

/// Runs a `ScriptedPass` as one of the driver's passes, mapping its outcome
/// exactly the way `RecordingSession.runPass` does: a `preempted` throw is a
/// deferral, anything else a failure. Lets a driver test drive the real yield
/// signal instead of being told what the pass decided.
func passResult(
    from pass: ScriptedPass, shouldYield: @escaping @Sendable () -> Bool
) async -> FinalizationDriver.PassResult {
    do {
        let segments = try await pass.run(
            retainedFiles: [:], shouldYield: shouldYield, onProgress: { _ in })
        return .replaced(segments)
    } catch TranscriptionError.preempted {
        return .preempted
    } catch {
        return .failed
    }
}

/// Yields a bounded number of times so queued work can land.
///
/// Only for the assertions that are negative — "no pass ran", "the awaiter is
/// still suspended". Those cannot be waited FOR, and a sleep would make them
/// wall-clock assertions; a fixed number of cooperative turns is the honest
/// version of "nothing was going to happen anyway".
func settle(turns: Int = 200) async {
    for _ in 0..<turns { await Task.yield() }
}

// MARK: - The summarization side

/// The engine the summary model hands out in a scheduling test.
///
/// It is never asked to stream: `ScriptedSummarizer` produces the documents
/// directly and ignores the engine it is given. This exists only so
/// `acquireEngine()` succeeds, because the scheduler acquires before it
/// generates and a failed acquire would short-circuit the very path under
/// test. Streaming from it at all means a real `Summarizer` slipped in.
struct InertTextEngine: TextGenerating {

    func stream(
        system: String, user: String, params: GenerationParams
    )
        -> AsyncThrowingStream<String, Error>
    {
        Issue.record("A scheduling test drove a real generation")
        return AsyncThrowingStream { $0.finish() }
    }
}

/// A scripted stand-in for the summarizer: one script per generation, each
/// saying which documents the stream yields and how it ends.
///
/// Which meeting the scheduler picked is only visible in the transcript it
/// handed over — the seam takes segments, not an id — so every generation's
/// segments are kept in order.
final class ScriptedSummarizer: Sendable {

    enum Script: Sendable {
        /// Yields each document and completes cleanly. Only a clean finish
        /// may be persisted.
        case documents([SummaryDocument])
        /// Yields each document and then throws: the model died mid-stream,
        /// which must leave nothing behind.
        case cutShort([SummaryDocument])
    }

    private struct State {
        var scripts: [Script]
        var transcripts: [[TranscriptSegment]] = []
        var yielded = 0
        var terminations = 0
        var captions = 0
        /// Yield this many documents, then wait for `releaseAll()`. The only
        /// way to act — start a recording — in the middle of a generation.
        var holdAfter: Int?
        var release = false
    }

    private let state: Mutex<State>
    private let captionText: String?

    init(_ scripts: [Script], caption: String? = nil) {
        state = Mutex(State(scripts: scripts))
        captionText = caption
    }

    /// One entry per generation, in the order the scheduler ran them.
    var transcripts: [[TranscriptSegment]] { state.withLock { $0.transcripts } }
    var generations: Int { state.withLock { $0.transcripts.count } }
    /// Documents handed to the consumer so far.
    var yielded: Int { state.withLock { $0.yielded } }
    /// Streams that ended — cleanly, or torn down by a consumer that gave up.
    /// The anchor an abandoned generation can be waited for on.
    var terminations: Int { state.withLock { $0.terminations } }
    var captions: Int { state.withLock { $0.captions } }

    func holdAfterDocument(_ count: Int) {
        state.withLock { state in
            state.holdAfter = count
            state.release = false
        }
    }

    func releaseAll() { state.withLock { $0.release = true } }

    var generate: SummaryGenerating {
        { [self] segments, _ in
            let script = state.withLock { state -> Script in
                state.transcripts.append(segments)
                return state.scripts.isEmpty ? .documents([]) : state.scripts.removeFirst()
            }
            return makeStream(script)
        }
    }

    var caption: CaptionGenerating {
        // `[self]` rather than capturing the `Mutex` itself: it is
        // non-copyable, so a capture list would consume it.
        { [self] _, _ in
            state.withLock { $0.captions += 1 }
            return captionText
        }
    }

    private func makeStream(_ script: Script) -> AsyncThrowingStream<SummaryDocument, Error> {
        let documents: [SummaryDocument]
        let endsInFailure: Bool
        switch script {
        case .documents(let scripted):
            documents = scripted
            endsInFailure = false
        case .cutShort(let scripted):
            documents = scripted
            endsInFailure = true
        }

        let (stream, continuation) = AsyncThrowingStream<SummaryDocument, Error>.makeStream()
        let producer = Task { [self] in
            for document in documents {
                await waitIfHeld()
                continuation.yield(document)
                state.withLock { $0.yielded += 1 }
            }
            if endsInFailure {
                continuation.finish(
                    throwing: ScriptedCaptureFailure(reason: "the generation was cut short"))
            } else {
                continuation.finish()
            }
        }
        continuation.onTermination = { [self] _ in
            state.withLock { $0.terminations += 1 }
            // A consumer that gives up must stop the generation: the real
            // engine's contract, and what keeps a held producer from
            // outliving its test.
            producer.cancel()
        }
        return stream
    }

    /// Yielding rather than sleeping, like `ScriptedPass`'s gate: the test
    /// releases, and the producer notices on its next turn.
    private func waitIfHeld() async {
        while state.withLock({ state in
            guard let holdAfter = state.holdAfter else { return false }
            return state.yielded >= holdAfter && !state.release
        }) {
            if Task.isCancelled { return }
            await Task.yield()
        }
    }
}

/// A summary document, with only the two fields the scheduler reads.
func summaryDocument(
    _ markdown: String, isFinal: Bool, modelName: String = "Scripted 1B"
) -> SummaryDocument {
    SummaryDocument(markdown: markdown, modelName: modelName, isFinal: isFinal)
}

// MARK: - Meetings planted on disk

/// Plants a meeting still pending transcription: saved, no provenance, with
/// retained audio beside it — exactly what quitting mid-pass leaves behind,
/// and the only shape the launch scan auto-resumes.
///
/// The audio is a few bytes nobody decodes: the scripted pass never opens the
/// files, and it is their PRESENCE that makes the meeting pending.
@MainActor
@discardableResult
func plantPendingMeeting(in harness: SessionHarness, minutesAgo: Int) async throws -> UUID {
    let id = UUID()
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo) * 60)
    let meta = MeetingMeta(
        id: id,
        title: MeetingMeta.autoTitle(startedAt: startedAt),
        startedAt: startedAt,
        endedAt: startedAt.addingTimeInterval(60),
        segmentCount: 0,
        hasSummary: false
    )
    try await harness.store.save(MeetingRecord(meta: meta, segments: []))
    for channel in AudioChannel.allCases {
        let url = harness.store.directory(for: id)
            .appending(
                path: MeetingStore.retainedAudioFileName(for: channel), directoryHint: .notDirectory)
        try Data("audio".utf8).write(to: url)
    }
    await harness.library.refresh()
    return id
}

/// Plants a finished, summary-less meeting: a transcript, `finalPass`
/// provenance and no audio — what the backfill scan exists to find. The
/// transcript text identifies it, because the summarizer seam is handed
/// segments rather than a meeting id.
@MainActor
@discardableResult
func plantTranscribedMeeting(
    in harness: SessionHarness, minutesAgo: Int, text: String
) async throws -> UUID {
    let id = UUID()
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo) * 60)
    let segments = [
        TranscriptSegment(channel: .microphone, speaker: .me, text: text, start: 0, end: 1)
    ]
    let meta = MeetingMeta(
        id: id,
        title: text,
        startedAt: startedAt,
        endedAt: startedAt.addingTimeInterval(60),
        segmentCount: segments.count,
        hasSummary: false,
        transcriptProvenance: TranscriptProvenance(
            source: .finalPass, modelName: ParakeetModel.modelID)
    )
    try await harness.store.save(MeetingRecord(meta: meta, segments: segments))
    await harness.library.refresh()
    return id
}
