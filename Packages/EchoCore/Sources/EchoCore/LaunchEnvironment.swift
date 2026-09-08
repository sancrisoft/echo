//
//  LaunchEnvironment.swift
//  EchoCore
//
//  The single reader of `ECHO_*` environment variables. Every debug flag the
//  app honors is a typed property here, populated only in DEBUG builds; a
//  release build sees defaults regardless of the environment. No other file
//  reads `ProcessInfo.processInfo.environment` (the boundary script checks).
//

import Foundation

public struct LaunchEnvironment: Sendable, Equatable {

    public enum Appearance: String, Sendable {
        case light
        case dark
    }

    /// `ECHO_DATA_ROOT`: run the app against another data folder. The way to
    /// launch Echo "from zero" or against a scratch library without touching
    /// the real one.
    public let dataRootOverride: URL?

    /// `ECHO_OPEN_WINDOW=1`: open the main window at launch (the app never
    /// does on its own).
    public let opensWindowAtLaunch: Bool

    /// `ECHO_APPEARANCE=light|dark`: force the appearance, for design review.
    public let appearanceOverride: Appearance?

    /// `ECHO_KEEP_RETAINED_AUDIO=1`: a successful transcription pass keeps the
    /// meeting's audio under debug names instead of deleting it, so a real
    /// meeting becomes a replayable fixture.
    public let keepsRetainedAudio: Bool

    /// `ECHO_INSTALLED_VERSION`: pretend this build is that version, to
    /// exercise the update check.
    public let installedVersionOverride: String?

    /// The process's environment, read once.
    public static let current = LaunchEnvironment(environment: ProcessInfo.processInfo.environment)

    /// Reads the flags from `environment`. Outside DEBUG every flag is its
    /// default, whatever the environment says.
    public init(environment: [String: String]) {
        #if DEBUG
            dataRootOverride = environment["ECHO_DATA_ROOT"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            opensWindowAtLaunch = environment["ECHO_OPEN_WINDOW"] == "1"
            appearanceOverride = environment["ECHO_APPEARANCE"].flatMap(Appearance.init(rawValue:))
            keepsRetainedAudio = environment["ECHO_KEEP_RETAINED_AUDIO"] == "1"
            installedVersionOverride = environment["ECHO_INSTALLED_VERSION"]
        #else
            dataRootOverride = nil
            opensWindowAtLaunch = false
            appearanceOverride = nil
            keepsRetainedAudio = false
            installedVersionOverride = nil
        #endif
    }

    /// An environment with every flag at its default.
    public static let none = LaunchEnvironment(environment: [:])
}
