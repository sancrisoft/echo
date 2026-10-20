//
//  CaptureAccess.swift
//  Recording
//
//  Whether Echo may capture one of its two channels — the microphone (You)
//  or the Mac's audio (Others) — as the welcome screen's permission rows draw
//  it: Allow, Open System Settings, or Allowed.
//
//  The two are read differently, and that is the point of one value over
//  both. The microphone's permission is read from macOS without asking. The
//  Mac's audio cannot be: macOS offers no way to read System Audio Recording,
//  a denied tap comes up as cleanly as a granted one and delivers silence,
//  and the check that does work — a tone of Echo's own, heard or not — is
//  also the request that raises the dialog (the #92 spike, 2026-10-19). So
//  that check runs only once Echo has asked, and until it has run the
//  answer is undecided.
//

import Audio

public enum CaptureAccess: Equatable, Sendable {

    /// Not asked, or not answered yet: macOS has not been asked about the
    /// microphone, or Echo has not asked about — or has not checked, or could
    /// not tell — the Mac's audio. The row offers Allow.
    case undecided

    /// Refused. Only System Settings can change it now.
    case denied

    case granted

    public var isGranted: Bool { self == .granted }

    init(_ authorization: MicrophoneAuthorization) {
        switch authorization {
        case .notDetermined: self = .undecided
        case .denied: self = .denied
        case .granted: self = .granted
        }
    }

    init(_ access: SystemAudioAccess) {
        switch access {
        case .granted: self = .granted
        case .denied: self = .denied
        case .unknown: self = .undecided
        }
    }
}
