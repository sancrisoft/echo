//
//  GitHubReleaseFeed.swift
//  Updates
//
//  Where Echo's releases live and how the latest one is read.
//
//  Echo ships as ad-hoc signed zips attached to GitHub releases, installed and
//  updated by scripts/install.sh; there is no Sparkle feed. A check is one
//  unauthenticated GET to api.github.com for the latest release's metadata. It
//  carries Echo's version in the User-Agent and nothing about the user or their
//  meetings, and one Settings toggle turns the automatic one off.
//

import Foundation

/// What GitHub reports as the newest release.
public struct LatestRelease: Equatable, Sendable {

    public var version: ReleaseVersion
    /// The tag exactly as published ("v0.0.12").
    public var tag: String
    /// The release's title ("Echo 0.0.12"), if it has one.
    public var title: String?
    /// The release page — notes, assets, the full changelog.
    public var pageURL: URL
    public var publishedAt: Date?

    public init(version: ReleaseVersion, tag: String, title: String?, pageURL: URL, publishedAt: Date?) {
        self.version = version
        self.tag = tag
        self.title = title
        self.pageURL = pageURL
        self.publishedAt = publishedAt
    }
}

/// Why a check produced no answer. `message` is what the Settings page shows.
public enum UpdateCheckFailure: Error, Equatable, LocalizedError {

    /// The request never got an HTTP answer: offline, DNS, timeout, TLS.
    case offline
    case http(Int)
    /// 403/429 — GitHub's unauthenticated limit is 60 requests an hour per
    /// address, which a busy office NAT can exhaust.
    case rateLimited
    case malformed(String)
    case unrecognizedTag(String)

    public var message: String {
        switch self {
        case .offline:
            return "Couldn't reach GitHub. Are you online?"
        case .rateLimited:
            return "GitHub is limiting update checks from this network right now. Try again in an hour."
        case .http(404):
            return "GitHub has no releases for Echo (HTTP 404)."
        case .http(let code):
            return "GitHub answered with HTTP \(code)."
        case .malformed:
            return "GitHub sent an answer Echo couldn't read."
        case .unrecognizedTag(let tag):
            return "The latest release is tagged “\(tag)”, which isn't a version Echo understands."
        }
    }

    public var errorDescription: String? { message }
}

/// Every URL a user might see — README, release notes, the Update button —
/// derives from `repository`, so the install command is one string everywhere
/// (a test holds the README and the script to it).
public enum GitHubReleaseFeed {

    public static let repository = "sancrisoft/echo"
    public static let defaultBranch = "main"

    public static var releasesPageURL: URL {
        url("https://github.com/\(repository)/releases")
    }

    public static var latestReleaseAPIURL: URL {
        url("https://api.github.com/repos/\(repository)/releases/latest")
    }

    public static var installScriptURL: URL {
        url("https://raw.githubusercontent.com/\(repository)/\(defaultBranch)/scripts/install.sh")
    }

    /// The README's one-liner, verbatim.
    public static var installCommand: String {
        "curl -fsSL \(installScriptURL.absoluteString) | bash"
    }

    /// The request a check sends. No cache: the point is today's answer.
    public static func latestReleaseRequest(appVersion: String) -> URLRequest {
        var request = URLRequest(url: latestReleaseAPIURL, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Echo/\(appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The fields of GitHub's release object this needs. Drafts and
    /// pre-releases never come back from /releases/latest, so there is
    /// nothing to filter.
    private struct Payload: Decodable {
        var tagName: String
        var name: String?
        var htmlUrl: URL
        var publishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlUrl = "html_url"
            case publishedAt = "published_at"
        }
    }

    public static func decodeLatest(_ data: Data) throws -> LatestRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            throw UpdateCheckFailure.malformed(String(describing: error))
        }
        guard let version = ReleaseVersion(payload.tagName) else {
            throw UpdateCheckFailure.unrecognizedTag(payload.tagName)
        }
        return LatestRelease(
            version: version,
            tag: payload.tagName,
            title: payload.name,
            pageURL: payload.htmlUrl,
            publishedAt: payload.publishedAt
        )
    }

    /// The three URLs above go through here. Their only variable parts are
    /// `repository` and `defaultBranch`, compile-time constants that
    /// `URL(string:)` cannot reject; the fallback is unreachable and exists
    /// because the initializer is failable and this repository forbids force
    /// unwraps. A typo in either constant fails the test that pins all three
    /// strings long before it reaches a user.
    private static func url(_ text: String) -> URL {
        URL(string: text) ?? URL(filePath: "/")
    }
}
