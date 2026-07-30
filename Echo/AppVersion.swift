import Foundation

/// The app's version as baked into the bundle at build time.
///
/// Release builds get their numbers injected by CI from the git tag
/// (MARKETING_VERSION = tag without the "v", CURRENT_PROJECT_VERSION = run
/// number), so this is the string internal testers report bugs against.
/// Local Xcode builds carry the static project values (1.0 (1)) and are
/// marked "dev" to keep them distinguishable from tagged releases.
enum AppVersion {
    /// Short display form, e.g. "v1.3 (42)" — or "v1.0 (1) dev" locally.
    static let display: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var text = "v\(short) (\(build))"
        #if DEBUG
        text += " dev"
        #endif
        return text
    }()
}
