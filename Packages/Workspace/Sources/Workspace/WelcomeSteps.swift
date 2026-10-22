//
//  WelcomeSteps.swift
//  Workspace
//
//  The design's welcome screen, as values: the three steps and
//  where each one stands, what each row offers, whether the user can go on,
//  and why not yet. Resolved from the session's four readings and nothing
//  else, so every state is checkable without a window.
//
//  Decisions the artboard does not draw are the product owner's (2026-10-19):
//  a permission never asked offers Allow, which raises macOS's dialog; a
//  denied one offers Open System Settings; a granted one reads Allowed. Start
//  using Echo waits for both permissions and both models; Record without notes
//  for both permissions and the transcription model only, because without the
//  summary model there is still a transcript. The reason beside a held-back
//  Start names the first step missing, in the rows' order.
//

import Recording

struct WelcomeSteps: Equatable {

    let microphone: CaptureAccess
    let systemAudio: CaptureAccess
    let transcription: RecordingReadiness
    let summary: SummaryReadiness

    /// Where a step stands, for its glyph.
    enum Progress: Equatable {
        case done
        case pending
        /// Something is happening on its own: a model coming down, or into
        /// memory. Not a fraction — each model line has its own.
        case working
    }

    /// What a permission's row offers on its right.
    enum PermissionControl: Equatable {
        case allow
        case openSettings
        case allowed
    }

    /// What a model's line shows after its name. One slot of fixed width:
    /// the bar and its figure while the model comes down or once it is in,
    /// and otherwise the models panel's own words and button in the bar's
    /// place, so text never resizes a bar (product owner, 2026-10-19).
    enum ModelSlot: Equatable {
        case downloading(percent: Int)
        case onDisk(size: String)
        case panel(ModelRow)
    }

    static func control(for access: CaptureAccess) -> PermissionControl {
        switch access {
        case .undecided: return .allow
        case .denied: return .openSettings
        case .granted: return .allowed
        }
    }

    var microphoneProgress: Progress { microphone.isGranted ? .done : .pending }
    var systemAudioProgress: Progress { systemAudio.isGranted ? .done : .pending }

    var modelsProgress: Progress {
        if transcription.isReady && summary.isReady { return .done }
        if case .downloading = transcription { return .working }
        switch summary {
        case .downloading, .loading: return .working
        case .waitingToDownload, .paused, .incomplete, .ready, .failed: return .pending
        }
    }

    var transcriptionSlot: ModelSlot {
        switch transcription {
        case .downloading: return .downloading(percent: transcription.downloadPercent ?? 0)
        case .ready: return .onDisk(size: OnDeviceModel.transcription.size)
        case .waitingToDownload, .downloadFailed: return .panel(.transcription(transcription))
        }
    }

    var summarySlot: ModelSlot {
        switch summary {
        case .downloading: return .downloading(percent: summary.downloadPercent ?? 0)
        case .ready: return .onDisk(size: OnDeviceModel.summary.size)
        case .waitingToDownload, .paused, .incomplete, .loading, .failed: return .panel(.summary(summary))
        }
    }

    private var permissionsGranted: Bool { microphone.isGranted && systemAudio.isGranted }

    var canStart: Bool { permissionsGranted && transcription.isReady && summary.isReady }

    var canRecordWithoutNotes: Bool { permissionsGranted && transcription.isReady }

    /// Why Start using Echo is held back: the first step missing, in the
    /// rows' order. `nil` once nothing is.
    var waitingOn: String? {
        if !microphone.isGranted { return "Waiting on the microphone." }
        if !systemAudio.isGranted { return "Waiting on System Audio Recording." }
        if !(transcription.isReady && summary.isReady) { return "Waiting on the models." }
        return nil
    }
}

/// Whether the window opens on the welcome screen at launch: the first time
/// Echo opens, and again at each launch while the user has not left it and
/// the models are not both on disk (product owner, 2026-10-19). Once left, it
/// never comes back.
public enum WelcomeGate {
    public static func showsAtLaunch(firstLaunch: Bool, hasLeftWelcome: Bool, modelsOnDisk: Bool) -> Bool {
        guard !hasLeftWelcome else { return false }
        return firstLaunch || !modelsOnDisk
    }
}
