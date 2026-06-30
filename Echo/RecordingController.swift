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

@Observable
@MainActor
final class RecordingController {

    let state = RecordingState()

    private let mic = MicrophoneCapture()
    private let system = SystemAudioCapture()
    private let pipeline = TranscriptionPipeline()

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
        state.status = "Pidiendo permisos…"

        wireCallbacks()
        state.markStarted()

        do {
            try await mic.start()
            try await system.start()
            await pipeline.start(appendingTo: state)
            state.status = ""
        } catch {
            state.status = error.localizedDescription
            await stop()
        }
    }

    func stop() async {
        mic.stop()
        system.stop()
        await pipeline.stop()
        state.markStopped()
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        // Capture `state`/`pipeline` directly (not `self`) so these real-time
        // audio callbacks don't race on the controller's `self` reference.
        mic.onLevel = { [state] level in
            Task { @MainActor in state.pushInput(level) }
        }
        mic.onSamples = { [pipeline] frames in
            Task { await pipeline.ingest(frames, from: .microphone) }
        }
        system.onLevel = { [state] level in
            Task { @MainActor in state.pushOutput(level) }
        }
        system.onSamples = { [pipeline] frames in
            Task { await pipeline.ingest(frames, from: .system) }
        }
    }
}
