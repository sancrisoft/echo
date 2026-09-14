//
//  ReleaseVersion.swift
//  Updates
//
//  The arithmetic behind a `vX.Y.Z` tag, and the one question that needs it:
//  which version is this Mac running?
//
//  Comparing versions is the whole truth about whether an update exists: a fix
//  is always a new version (no rebuilds under an existing tag, decided
//  2026-09-04), so the installer's code-directory-hash comparison is
//  idempotency, not a second signal.
//

import EchoCore
import Foundation

/// A release's version: the number behind a `vX.Y.Z` tag.
public struct ReleaseVersion: Hashable, Comparable, Sendable, CustomStringConvertible {

    /// Numeric components as written — [0, 0, 12] for "v0.0.12".
    public let components: [Int]

    /// Anything after a hyphen — "rc.1" for "v0.1.0-rc.1". Nil for a release.
    public let preRelease: String?

    /// Accepts "v0.0.12", "0.0.12", "V1.2" and "v0.1.0-rc.1" (surrounding
    /// whitespace ignored). Nil for anything that is not digits and dots —
    /// "", "latest", "1.0.x", a bare "v".
    public init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }

        var suffix: String?
        if let dash = body.firstIndex(of: "-") {
            suffix = String(body[body.index(after: dash)...])
            body = String(body[..<dash])
            if suffix?.isEmpty == true { return nil }
        }
        guard !body.isEmpty else { return nil }

        var parsed: [Int] = []
        for piece in body.split(separator: ".", omittingEmptySubsequences: false) {
            guard !piece.isEmpty, piece.allSatisfy(\.isNumber), let number = Int(piece) else { return nil }
            parsed.append(number)
        }
        components = parsed
        preRelease = suffix
    }

    /// "v0.0.12" — the git tag form.
    public var tag: String { "v\(description)" }

    /// "0.0.12", or "0.1.0-rc.1".
    public var description: String {
        let numbers = components.map(String.init).joined(separator: ".")
        return preRelease.map { "\(numbers)-\($0)" } ?? numbers
    }

    /// "1.0" and "1.0.0" are the same version: trailing zeros never count.
    private var normalized: [Int] {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        return trimmed
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.normalized == rhs.normalized && lhs.preRelease == rhs.preRelease
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(normalized)
        hasher.combine(preRelease)
    }

    /// Numeric components first; with equal numbers a pre-release sorts
    /// before the release it precedes (0.1.0-rc.1 < 0.1.0), and two
    /// pre-releases compare as plain strings.
    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let a = lhs.normalized
        let b = rhs.normalized
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y }
        }
        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        case (.some(let p), .some(let q)): return p < q
        }
    }
}

extension ReleaseVersion {

    /// The version the update check compares against — nil only when the
    /// bundle's version string is unparseable, which `UpdateChecker.evaluate`
    /// reports as a failure rather than guessing.
    ///
    /// The reading happens here rather than in `EchoCore`: `AppIdentity` gives
    /// the bundle's numbers as strings and `LaunchEnvironment` gives the debug
    /// override, and turning either into a `ReleaseVersion` is this package's
    /// vocabulary — `EchoCore` sits below it and may not name the type.
    public static var installed: ReleaseVersion? {
        installed(
            bundleVersion: AppIdentity.version.short,
            override: LaunchEnvironment.current.installedVersionOverride
        )
    }

    /// The rule behind `installed`, as a pure function so a test can state it.
    ///
    /// `ECHO_INSTALLED_VERSION` is how the "update available" path is
    /// exercised from a dev build, whose own 1.0 is ahead of every tag. It is
    /// nil outside DEBUG because `LaunchEnvironment` makes it so; there is no
    /// second `#if` here.
    public static func installed(bundleVersion: String, override: String?) -> ReleaseVersion? {
        if let override, let forced = ReleaseVersion(override) { return forced }
        return ReleaseVersion(bundleVersion)
    }
}
