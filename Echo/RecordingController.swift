//
//  RecordingController.swift
//  Echo
//
//  Orchestrates a recording session: starts the two native capture channels,
//  routes their loudness levels into `RecordingState` for the waveforms, and
//  feeds 16 kHz mono Float frames into the transcription pipeline.
//
//  This is the object the UI talks to (injected via the environment).
//

import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers
import os

@Observable
@MainActor
final class RecordingController {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "RecordingController")

    let state = RecordingState()

    private let mic = MicrophoneCapture()
    private let system = SystemAudioCapture()
    private let pipeline = TranscriptionPipeline()
    private let routeMonitor = OutputRouteMonitor()
    private var echoMode: EchoModeMachine?
    // Per-session (built in `startEchoHandling`): wraps a fresh engine stage
    // and applies the mode machine's current mode to the audio path.
    private var switchingStage: SwitchingAECStage?
    private let summarizer = SummarizationPipeline()
    private let llamaServer = LlamaServerManager()
    private var sessionGeneration = 0
    private(set) var gemmaModelPath: String? = LlamaServerConfig.storedModelPath

    var isRecording: Bool { state.isRecording }

    init() {
        // Warm up the (large) models at launch so pressing record is instant.
        Task { await prepare() }
    }

    /// Loads the transcription models ahead of time. Idempotent.
    func prepare() async {
        await pipeline.preload(updating: state)
    }

    // MARK: - Control

    func toggle() async {
        if state.isRecording {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard !state.isRecording else { return }
        sessionGeneration += 1
        state.status = "Requesting permissions…"

        let aecStage = startEchoHandling()
        wireCallbacks(aecStage: aecStage)
        state.markStarted()

        do {
            await pipeline.start(appendingTo: state)
            try await mic.start()
            try await system.start()
            state.status = ""
        } catch {
            state.status = error.localizedDescription
            await stop(summarize: false)
        }
    }

    func stop() async {
        await stop(summarize: true)
    }

    func selectGemmaModel() {
        let panel = NSOpenPanel()
        panel.title = "Select Gemma GGUF model"
        panel.prompt = "Select"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        LlamaServerConfig.storeModelURL(url)
        gemmaModelPath = url.path
    }

    func retrySummary() async {
        guard !state.isRecording else { return }
        await generateSummary(from: state.segments, sessionGeneration: sessionGeneration)
    }

    private func stop(summarize: Bool) async {
        mic.stop()
        system.stop()
        stopEchoHandling()
        await pipeline.stop()
        let transcript = state.segments
        let generation = sessionGeneration
        state.markStopped()

        guard summarize else { return }
        await generateSummary(from: transcript, sessionGeneration: generation)
    }

    private func generateSummary(from transcript: [TranscriptSegment], sessionGeneration generation: Int) async {
        guard !transcript.isEmpty else {
            state.markSummaryUnavailable("No transcript was captured.")
            return
        }

        state.markSummaryGenerating()

        do {
            let llamaConfig = try LlamaServerConfig.resolved()
            try await llamaServer.ensureRunning(config: llamaConfig)

            var latest: MeetingSummary?
            let stream = await summarizer.generate(from: transcript)
            for try await partial in stream {
                guard generation == sessionGeneration, !state.isRecording else { return }
                latest = partial
                state.markSummaryStreaming(partial)
            }

            guard generation == sessionGeneration, !state.isRecording else { return }
            if let latest {
                state.markSummaryReady(latest)
            } else {
                state.markSummaryUnavailable("Gemma returned an empty summary.")
            }
        } catch {
            guard generation == sessionGeneration, !state.isRecording else { return }
            state.markSummaryFailed(error.localizedDescription)
        }
    }

    // MARK: - Wiring

    private func wireCallbacks(aecStage: any AECStage) {
        // Capture `state`/`pipeline`/`aecStage` directly (not `self`) so these
        // real-time audio callbacks don't race on the controller's `self`
        // reference.
        mic.onLevel = { [state] level in
            Task { @MainActor in state.pushInput(level) }
        }
        mic.onSamples = { [pipeline] frames in
            let cleaned = aecStage.processMicSamples(frames)
            Task { await pipeline.ingest(cleaned, from: .microphone) }
        }
        system.onLevel = { [state] level in
            Task { @MainActor in state.pushOutput(level) }
        }
        system.onSamples = { [pipeline] frames in
            // Read-only fan-out (ADR-002): the far end gets a value copy; the
            // Team ingest path below must stay byte-identical to today.
            aecStage.feedFarEnd(frames)
            Task { await pipeline.ingest(frames, from: .system) }
        }
    }

    // MARK: - Echo handling (SP-001)

    /// Builds the session's mode machine and AEC stage and returns the stage
    /// for the capture callbacks to run.
    private func startEchoHandling() -> any AECStage {
        var machine = EchoModeMachine(initialRoute: routeMonitor.currentRoute())

        // A fresh engine per session: no adaptation state leaks across
        // recordings, and an init failure only degrades this session.
        let engine = WebRTCAECStage()
        let generation = sessionGeneration
        engine.onEngineEvent = { [weak self] healthy in
            // May arrive on either capture thread; the machine and the notice
            // live on the main actor. The generation guard drops any late
            // event from an engine of a previous session.
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                self.handleEngineEvent(healthy: healthy)
            }
        }

        // SP-001 US-8: an engine that never comes up must not block the
        // session — it starts on the degraded path (raw mic + dedup) instead.
        if machine.mode == .cancelling, !engine.isHealthy,
           let effect = machine.handle(.engineFailed) {
            state.applyEchoHandlingEffect(effect)
        }

        Self.log.info("Echo-handling mode: \(machine.mode.rawValue, privacy: .public)")
        let stage = SwitchingAECStage(engineStage: engine, mode: machine.mode)
        echoMode = machine
        switchingStage = stage
        routeMonitor.onRouteChange = { [weak self] route in
            self?.handleRouteChange(route)
        }
        routeMonitor.start()
        return stage
    }

    private func stopEchoHandling() {
        routeMonitor.stop()
        routeMonitor.onRouteChange = nil
        switchingStage?.reset()
        switchingStage = nil
        echoMode = nil
    }

    private func handleRouteChange(_ route: OutputRouteClass) {
        guard var machine = echoMode else { return }
        let previous = machine.mode
        let effect = machine.handle(.routeChanged(route))
        echoMode = machine

        if machine.mode != previous {
            Self.log.info("""
            Echo-handling mode: \(previous.rawValue, privacy: .public) → \
            \(machine.mode.rawValue, privacy: .public)
            """)
            switchingStage?.setMode(machine.mode)
            // SP-001: on any route change the canceller resets and re-converges.
            switchingStage?.reset()
        }
        if let effect {
            state.applyEchoHandlingEffect(effect)
        }
    }

    private func handleEngineEvent(healthy: Bool) {
        guard var machine = echoMode else { return }
        let previous = machine.mode
        let effect = machine.handle(healthy ? .engineRecovered : .engineFailed)
        echoMode = machine

        if machine.mode != previous {
            Self.log.info("""
            Echo-handling mode: \(previous.rawValue, privacy: .public) → \
            \(machine.mode.rawValue, privacy: .public) (engine \
            \(healthy ? "recovered" : "failed", privacy: .public))
            """)
            // No reset here: Cancelling ↔ Degraded keeps the engine fed, and
            // recovery means it is already processing frames successfully.
            switchingStage?.setMode(machine.mode)
        }
        if let effect {
            state.applyEchoHandlingEffect(effect)
        }
    }
}
