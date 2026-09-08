//
//  ModelDeliveryError.swift
//  ModelDelivery
//
//  Every failure this package surfaces, in one enum (architecture §7).
//  `LocalizedError` because each of these can reach a user: they are what a
//  first-run download shows when it cannot finish, and the copy has to say
//  what to do next rather than name a subsystem.
//
//  Deliberately absent: a "cancelled" case. A pause is a persisted intent the
//  caller records before cancelling, never a `CancellationError` read back
//  after the fact — inferring progress or intent from an error is how a
//  paused download turns into a failed one.
//

import Foundation

public enum ModelDeliveryError: Error, LocalizedError, Equatable {

    /// The server answered something the transfer cannot use. Carries the code
    /// because the recovery differs: 401/403 means the signed CDN URL expired
    /// and a fresh metadata fetch fixes it, while 5xx is worth a retry.
    case unexpectedStatus(code: Int)

    /// The connection ended cleanly but short of the announced size. Never
    /// silently accepted: the partial stays on disk so the next attempt
    /// resumes, but this transfer did not complete.
    case truncatedTransfer(bytesOnDisk: Int64, expectedBytes: Int64)

    /// Every attempt stalled — surfaced with a retry hint.
    case downloadStalled

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let code):
            return "The model server answered with HTTP \(code)."
        case .truncatedTransfer(let bytesOnDisk, let expectedBytes):
            return "The download ended early (\(bytesOnDisk) of \(expectedBytes) bytes). Retry to resume it."
        case .downloadStalled:
            return "The download stalled and made no progress. Check your connection and retry."
        }
    }
}
