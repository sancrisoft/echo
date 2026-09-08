//
//  AppIdentity.swift
//  EchoCore
//
//  Who this app is: the bundle identifier, the unified-log subsystem every
//  Logger uses, and the running build's version. Release builds get their
//  numbers injected by CI from the git tag (MARKETING_VERSION = tag without the
//  "v", CURRENT_PROJECT_VERSION = run number); local builds carry the static
//  project values and are marked "dev".
//

import Foundation

public enum AppIdentity {

    /// `com.sancrisoft.Echo` — also the prefix of every product identifier.
    public static let bundleIdentifier = "com.sancrisoft.Echo"

    /// The one `os.Logger` subsystem; categories are per file.
    public static let logSubsystem = "com.sancrisoft.Echo"

    /// The running build's version, read from the main bundle.
    public static let version = AppVersion(bundle: .main)
}

/// The running build's version numbers.
public struct AppVersion: Hashable, Sendable {

    /// `CFBundleShortVersionString`, e.g. "0.0.13"; "?" when unknown.
    public let short: String
    /// `CFBundleVersion`, e.g. "42"; "?" when unknown.
    public let build: String

    public init(short: String, build: String) {
        self.short = short
        self.build = build
    }

    /// Reads the version from a bundle's Info.plist.
    public init(bundle: Bundle) {
        let info = bundle.infoDictionary
        self.init(
            short: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?"
        )
    }

    /// "v0.0.13 (42)", with " dev" appended in DEBUG builds.
    public var display: String {
        var text = "v\(short) (\(build))"
        #if DEBUG
            text += " dev"
        #endif
        return text
    }
}
