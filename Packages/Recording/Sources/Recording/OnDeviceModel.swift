//
//  OnDeviceModel.swift
//  Recording
//
//  The two models Echo runs on the Mac, named as the surfaces name them: the
//  models panel's rows and the welcome screen's.
//
//  The names belong to each model's owner (`ParakeetModel`, `SummaryModel`);
//  this only carries them up to the packages that draw them, which import
//  neither, so a model renamed in its package is renamed everywhere.
//

import Summarization
import Transcription

public struct OnDeviceModel: Equatable, Sendable {

    /// The model's human name ("Parakeet v3 (0.6B)").
    public let name: String

    /// Its size on disk, a display string and never a progress input.
    public let size: String

    /// The credit its licence requires wherever the model is named, if any.
    public let attribution: String?

    /// The model a recording waits for.
    public static let transcription = OnDeviceModel(
        name: ParakeetModel.modelDisplayName,
        size: ParakeetModel.modelDisplaySize,
        attribution: ParakeetModel.attribution
    )

    /// The model that writes the notes.
    public static let summary = OnDeviceModel(
        name: SummaryModel.modelDisplayName,
        size: SummaryModel.modelDisplaySize,
        attribution: nil
    )
}
