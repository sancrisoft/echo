//
//  UpdateChecker.swift
//  Updates
//
//  The update state every surface renders: Settings, the app menu, and the
//  prompt Echo raises at launch.
//
//  `status` is the last *answer* and survives a re-check (`isChecking` is
//  separate), so "Update available" never flickers off while the daily check
//  is in flight.
//

import EchoCore
import Foundation
import Observation

@Observable
@MainActor
public final class UpdateChecker {

    public enum Status: Equatable, Sendable {
        /// Never checked (or the automatic check is still pending).
        case idle
        case upToDate(LatestRelease)
        case available(LatestRelease)
        case failed(String)
    }

    /// The network, injectable: tests hand in canned answers.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The version this build compares against — nil only if the bundle's
    /// version string is unparseable, which `evaluate` reports as a failure
    /// rather than guessing.
    public let installedVersion: ReleaseVersion?

    public private(set) var status: Status = .idle
    public private(set) var isChecking = false
    public private(set) var lastCheckedAt: Date?

    /// What the last Update Now left behind when it failed, handed in at
    /// launch from the updater's report file (see `UpdateInstaller`). Shown in
    /// Settings for this run only: the report is consumed when read.
    public private(set) var lastInstallFailure: String?

    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var automatic: Task<Void, Never>?

    public init(
        installedVersion: ReleaseVersion? = ReleaseVersion.installed,
        appVersion: String = AppIdentity.version.short,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.installedVersion = installedVersion
        self.appVersion = appVersion
        self.transport = transport
    }

    /// The newer release, when the last check found one.
    public var availableRelease: LatestRelease? {
        if case .available(let release) = status { return release }
        return nil
    }

    public func noteInstallFailure(_ message: String) {
        lastInstallFailure = message
    }

    /// Runs one check. Concurrent callers (the daily timer and a click on
    /// Check for Updates) share a single request.
    public func check() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await performCheck() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func performCheck() async {
        isChecking = true
        defer {
            isChecking = false
            lastCheckedAt = Date()
        }
        do {
            let latest = try await Self.fetchLatest(transport: transport, appVersion: appVersion)
            status = Self.evaluate(installed: installedVersion, latest: latest)
        } catch let error as UpdateCheckFailure {
            status = .failed(error.message)
            // Offline is ordinary for a laptop; anything else is worth a trace.
            if error != .offline {
                ErrorTrace.record("Update check failed", error: error, category: "Updates")
            }
        } catch {
            status = .failed(UpdateCheckFailure.offline.message)
        }
    }

    /// The comparison, pure: newer on GitHub means available; equal or a
    /// local build ahead of every tag (a dev build's 1.0) means up to date.
    public nonisolated static func evaluate(installed: ReleaseVersion?, latest: LatestRelease) -> Status {
        guard let installed else {
            return .failed("Couldn't read this build's version.")
        }
        return latest.version > installed ? .available(latest) : .upToDate(latest)
    }

    /// One request, mapped to `UpdateCheckFailure`. Any transport failure — no
    /// route, DNS, timeout, TLS — is `.offline`: the user's remedy is the same.
    public nonisolated static func fetchLatest(
        transport: Transport,
        appVersion: String
    ) async throws -> LatestRelease {
        let request = GitHubReleaseFeed.latestReleaseRequest(appVersion: appVersion)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw UpdateCheckFailure.offline
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 403, 429: throw UpdateCheckFailure.rateLimited
            default: throw UpdateCheckFailure.http(http.statusCode)
            }
        }
        return try GitHubReleaseFeed.decodeLatest(data)
    }

    // MARK: Automatic checks

    /// Checks once shortly after launch, then daily, for as long as
    /// `isEnabled` says so. The preference is read at every tick, so flipping
    /// the toggle needs no restart — off simply skips the next ticks.
    public func startAutomaticChecks(
        initialDelay: Duration = .seconds(30),
        interval: Duration = .seconds(24 * 60 * 60),
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        automatic?.cancel()
        automatic = Task { [weak self] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                guard let self else { return }
                if isEnabled() {
                    await self.check()
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopAutomaticChecks() {
        automatic?.cancel()
        automatic = nil
    }
}
