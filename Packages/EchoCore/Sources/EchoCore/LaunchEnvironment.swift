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

    /// What `ECHO_SNAPSHOT_PATH` renders.
    public enum SnapshotScene: String, Sendable {
        /// The library with nothing selected.
        case library
        /// The first meeting, on its Summary tab.
        case summary
        /// The first meeting, on its Transcript tab.
        case transcript
        case trash
        case settings
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

    /// `ECHO_SNAPSHOT_PATH=<file.png>`: render the main window to that file
    /// once its content has loaded, then quit. The design-review and smoke-test
    /// hook; pixels cannot be captured from outside a window on this macOS.
    public let snapshotPath: URL?

    /// `ECHO_SNAPSHOT_SCENE=library|summary|transcript|trash|settings`: which
    /// surface the snapshot shows. Defaults to the library.
    public let snapshotScene: SnapshotScene

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
            snapshotPath = environment["ECHO_SNAPSHOT_PATH"].map { URL(filePath: $0, directoryHint: .notDirectory) }
            snapshotScene = environment["ECHO_SNAPSHOT_SCENE"].flatMap(SnapshotScene.init(rawValue:)) ?? .library
            keepsRetainedAudio = environment["ECHO_KEEP_RETAINED_AUDIO"] == "1"
            installedVersionOverride = environment["ECHO_INSTALLED_VERSION"]
        #else
            dataRootOverride = nil
            opensWindowAtLaunch = false
            appearanceOverride = nil
            snapshotPath = nil
            snapshotScene = .library
            keepsRetainedAudio = false
            installedVersionOverride = nil
        #endif
    }

    /// An environment with every flag at its default.
    public static let none = LaunchEnvironment(environment: [:])
}
