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

    /// The volume is below the floor a multi-GB download needs. Refused before
    /// the first request rather than discovered several GB in, where the
    /// failure would be a truncated file and a wasted hour.
    case insufficientDiskSpace(freeBytes: Int64, requiredBytes: Int64)

    /// The repo answered without the size, etag or location a transfer needs.
    /// Its own case rather than a crash on a force unwrap: the recovery is a
    /// retry, and the message has to say which file.
    case missingFileMetadata(file: String)

    /// A committed file's bytes do not hash to the sha256 the repo published
    /// for it. Nothing is recorded and the file is dropped, so the next attempt
    /// re-fetches it rather than handing the runtime a corrupt tensor file.
    case integrityCheckFailed(file: String)

    /// The snapshot pass returned but a resolved file is still missing on
    /// disk — observed once with stale staging metadata after an interrupted
    /// download. Retrying is cheap (complete files are skipped) and heals it.
    case snapshotVerificationFailed

    /// Anything else the download failed with, already localized.
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let code):
            return "The model server answered with HTTP \(code)."
        case .truncatedTransfer(let bytesOnDisk, let expectedBytes):
            return "The download ended early (\(bytesOnDisk) of \(expectedBytes) bytes). Retry to resume it."
        case .downloadStalled:
            return "The download stalled and made no progress. Check your connection and retry."
        case .insufficientDiskSpace(let freeBytes, let requiredBytes):
            return """
                The download needs \(Self.gigabytes(requiredBytes)) free and this Mac has \
                \(Self.gigabytes(freeBytes)). Free up some space and retry.
                """
        case .missingFileMetadata(let file):
            return "The model server did not describe \(file). Retry the download."
        case .integrityCheckFailed(let file):
            return "\(file) did not match its published checksum and was discarded. Retry the download."
        case .snapshotVerificationFailed:
            return "The downloaded model files did not pass verification. Retry to resume the download."
        case .downloadFailed(let message):
            return message
        }
    }

    /// Byte counts reach a user as whole GB, the unit a download is discussed
    /// in; the decimal GB the volume itself reports, not GiB.
    private static func gigabytes(_ bytes: Int64) -> String {
        "\(bytes / 1_000_000_000) GB"
    }
}
