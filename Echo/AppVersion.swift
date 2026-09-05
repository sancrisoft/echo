import Foundation

/// The app's version as baked into the bundle at build time.
///
/// Release builds get their numbers injected by CI from the git tag
/// (MARKETING_VERSION = tag without the "v", CURRENT_PROJECT_VERSION = run
/// number), so this is the string internal testers report bugs against.
/// Local Xcode builds carry the static project values (1.0 (1)) and are
/// marked "dev" to keep them distinguishable from tagged releases.
///
/// `nonisolated`: everything here is a read of the bundle, and
/// `UpdateChecker`'s default argument evaluates `release` off the main actor.
nonisolated enum AppVersion {

    /// CFBundleShortVersionString — "0.0.12" in a tagged release, "1.0" locally.
    static let short: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    /// CFBundleVersion — the CI run number in a release, "1" locally.
    static let build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

    /// Short display form, e.g. "v1.3 (42)" — or "v1.0 (1) dev" locally.
    static let display: String = {
        var text = "v\(short) (\(build))"
        #if DEBUG
        text += " dev"
        #endif
        return text
    }()

    /// The installed version as the update check compares it. DEBUG builds
    /// honor `ECHO_INSTALLED_VERSION=0.0.1` so the "update available" path
    /// can be exercised against the real releases from a dev build, whose
    /// 1.0 is otherwise ahead of every tag.
    static var release: ReleaseVersion? {
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["ECHO_INSTALLED_VERSION"],
           let version = ReleaseVersion(forced) {
            return version
        }
        #endif
        return ReleaseVersion(short)
    }
}
