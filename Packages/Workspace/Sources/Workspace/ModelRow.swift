//
//  ModelRow.swift
//  Workspace
//
//  One on-device model's row, as the design draws it: what the model is,
//  one honest sentence about what it is doing, its state on the right, and
//  the one action that state offers. A value resolved from the session's two
//  readings and nothing else, so every state can be checked without a window
//  and the welcome screen can say the same words in its own layout.
//
//  The transcription model has no Pause and no interrupted download: its
//  engine has neither, and a recording waits for it, so its download shows
//  the real percentage only (product owner, 2026-10-19).
//

import Recording

struct ModelRow: Equatable, Identifiable {

    enum Model: Equatable, Hashable {
        case transcription
        case summary
    }

    /// What the right side of the row shows.
    enum Status: Equatable {
        /// A word for a state at rest: "Waiting to download", "Paused".
        case words(String)
        /// A download running, as the whole percent the session reads from
        /// the one clamp. The bar is drawn from the same number, so the bar
        /// and the figure beside it can never disagree.
        case progress(percent: Int)
        /// On disk, coming into memory.
        case loading
        /// On disk.
        case ready
        /// Nothing but the row's action: a failure, whose reason is the row's
        /// sentence.
        case actionOnly
    }

    /// The one action a state offers, each a verb its model's owner has.
    enum Action: Equatable {
        case pause
        case resume
        case resumeDownload
        case retry

        var title: String {
            switch self {
            case .pause: return "Pause"
            case .resume: return "Resume"
            case .resumeDownload: return "Resume download"
            case .retry: return "Retry"
            }
        }
    }

    let model: Model
    let detail: String
    let status: Status
    let action: Action?
    let isFailure: Bool

    var id: Model { model }

    /// What the model is for, before its name: "Transcription", "Summary".
    var role: String {
        switch model {
        case .transcription: return "Transcription"
        case .summary: return "Summary"
        }
    }

    var identity: OnDeviceModel {
        switch model {
        case .transcription: return .transcription
        case .summary: return .summary
        }
    }

    /// Both rows while either model is not ready; none once both are — the
    /// panel is gone, and the meetings start at the top of the pane.
    static func rows(transcription: RecordingReadiness, summary: SummaryReadiness) -> [ModelRow] {
        guard !(transcription.isReady && summary.isReady) else { return [] }
        return [.transcription(transcription), .summary(summary)]
    }

    static func transcription(_ readiness: RecordingReadiness) -> ModelRow {
        // The CC-BY-4.0 credit travels with the model's name, the one place
        // the model is named, and is never moved off it.
        let purpose =
            ["Transcribes each meeting after it ends", OnDeviceModel.transcription.attribution]
            .compactMap { $0 }
            .joined(separator: " · ")
        switch readiness {
        case .waitingToDownload:
            return ModelRow(
                model: .transcription, detail: purpose, status: .words(waitingWords), action: nil, isFailure: false)
        case .downloading:
            return ModelRow(
                model: .transcription, detail: purpose, status: .progress(percent: readiness.downloadPercent ?? 0),
                action: nil, isFailure: false)
        case .downloadFailed(let reason):
            return ModelRow(model: .transcription, detail: reason, status: .actionOnly, action: .retry, isFailure: true)
        case .ready:
            return ModelRow(model: .transcription, detail: purpose, status: .ready, action: nil, isFailure: false)
        }
    }

    static func summary(_ readiness: SummaryReadiness) -> ModelRow {
        let purpose = "Writes the meeting notes after each recording"
        switch readiness {
        case .waitingToDownload:
            return ModelRow(
                model: .summary, detail: purpose, status: .words(waitingWords), action: nil, isFailure: false)
        case .downloading:
            return ModelRow(
                model: .summary, detail: purpose, status: .progress(percent: readiness.downloadPercent ?? 0),
                action: .pause, isFailure: false)
        case .paused:
            return ModelRow(
                model: .summary, detail: "Paused by you. Resuming skips what is already on disk.",
                status: .words("Paused"), action: .resume, isFailure: false)
        case .incomplete:
            return ModelRow(
                model: .summary,
                detail:
                    "The app quit mid-download. No percentage here on purpose — the partial byte count is not trustworthy.",
                status: .words("Download incomplete"), action: .resumeDownload, isFailure: false)
        case .loading:
            return ModelRow(
                model: .summary,
                detail: "On disk. Coming into memory for this meeting, and released again when it goes idle.",
                status: .loading, action: nil, isFailure: false)
        case .ready:
            return ModelRow(model: .summary, detail: purpose, status: .ready, action: nil, isFailure: false)
        case .failed(let reason):
            return ModelRow(model: .summary, detail: reason, status: .actionOnly, action: .retry, isFailure: true)
        }
    }

    private static let waitingWords = "Waiting to download"
}
