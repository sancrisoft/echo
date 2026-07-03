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
    // Pass-through until S2 lands the real engine (ADR-002 seam).
    private let aecStage: any AECStage = PassthroughAECStage()
    private let routeMonitor = OutputRouteMonitor()
    private var echoMode: EchoModeMachine?
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

        wireCallbacks()
        startEchoHandling()
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

    private func wireCallbacks() {
        // Capture `state`/`pipeline` directly (not `self`) so these real-time
        // audio callbacks don't race on the controller's `self` reference.
        mic.onLevel = { [state] level in
            Task { @MainActor in state.pushInput(level) }
        }
        mic.onSamples = { [pipeline, aecStage] frames in
            let cleaned = aecStage.processMicSamples(frames)
            Task { await pipeline.ingest(cleaned, from: .microphone) }
        }
        system.onLevel = { [state] level in
            Task { @MainActor in state.pushOutput(level) }
        }
        system.onSamples = { [pipeline, aecStage] frames in
            // Read-only fan-out (ADR-002): the far end gets a value copy; the
            // Team ingest path below must stay byte-identical to today.
            aecStage.feedFarEnd(frames)
            Task { await pipeline.ingest(frames, from: .system) }
        }
    }

    // MARK: - Echo handling (SP-001)

    private func startEchoHandling() {
        var machine = EchoModeMachine(initialRoute: routeMonitor.currentRoute())
        Self.log.info("Echo-handling mode: \(machine.mode.rawValue, privacy: .public)")
        echoMode = machine
        routeMonitor.onRouteChange = { [weak self] route in
            self?.handleRouteChange(route)
        }
        routeMonitor.start()
    }

    private func stopEchoHandling() {
        routeMonitor.stop()
        routeMonitor.onRouteChange = nil
        aecStage.reset()
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
            // SP-001: on any route change the canceller resets and re-converges.
            aecStage.reset()
        }
        if let effect {
            // S4 binds the degradation notice to UI; until then it's log-only.
            Self.log.info("Echo-handling effect: \(String(describing: effect), privacy: .public)")
        }
    }
}
