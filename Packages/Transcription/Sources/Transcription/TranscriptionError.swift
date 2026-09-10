//
//  TranscriptionError.swift
//  Transcription
//
//  The pass's failure vocabulary. `preempted` is deliberately in here with
//  the failures but is NOT one: a pass that yields to a starting recording is
//  a deferral, and the finalization machine classifies it as such rather than
//  spending one of the meeting's two attempts on it.
//

import Foundation

public enum TranscriptionError: Error, Equatable, LocalizedError {
    /// No complete model set on disk right now — the pass cannot run. The
    /// meeting stays pending and a later launch's resume scan retries it.
    case modelUnavailable
    /// Loading the Core ML models failed.
    case modelLoadFailed(String)
    /// `shouldYield` asked the pass to stop (recording preemption). Not a
    /// failed attempt.
    case preempted
    /// The retained file couldn't be opened or read as 16 kHz Float PCM.
    case unreadableAudio(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "The transcription model isn't on disk yet."
        case .modelLoadFailed(let reason):
            return "The transcription model failed to load: \(reason)"
        case .preempted:
            return "Transcription paused because a recording started."
        case .unreadableAudio(let reason):
            return "The recorded audio couldn't be read: \(reason)"
        }
    }
}
