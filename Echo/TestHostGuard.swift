//
//  TestHostGuard.swift
//  Echo
//
//  Detects when this process is the unit-test HOST, so launch side effects
//  can be skipped wholesale.
//
//  Why this exists: `xcodebuild test` launches the real Echo.app as the test
//  host, and until 2026-08-06 that host booted the FULL production launch
//  path against the real data folder (~/Library/Application Support/Echo) —
//  speech-model preload, summary/final-pass downloads, retired-model cleanup,
//  trash purge, retention-staging sweeps and finalization resume. Run tests
//  while a real Echo instance is recording and the two instances race the
//  same store: a test run's sweep deleted the retention staging a live
//  session was writing, and a persisted meeting's meta.json vanished within
//  seconds ("Recording live-floor provenance failed … meta.json no such
//  file"). The historical "Skipping unreadable meeting folder" floods in the
//  error trace have the same cause. Under a test host the app must be inert
//  scaffolding: tests construct their own objects against temp dirs.
//

import Foundation

nonisolated enum TestHost {

    /// True when this process is the test runner's host app rather than a
    /// real user launch. Belt and braces, because a false negative corrupts
    /// the user's real store while a false positive merely skips warm-up in
    /// a debug run:
    ///
    /// * `NSClassFromString("XCTestCase")` — the XCTest runtime is linked
    ///   into the host for both XCTest and Swift Testing bundles (Swift
    ///   Testing rides the same injected test session).
    /// * The `XCTest*` environment keys Xcode sets on the host process
    ///   (`XCTestConfigurationFilePath` classically, `XCTestBundlePath` /
    ///   `XCTestSessionIdentifier` on newer toolchains).
    ///
    /// Computed exactly once: launch gates read it from several inits and the
    /// answer can never change mid-process.
    static let isActive: Bool = {
        if NSClassFromString("XCTestCase") != nil { return true }
        let environment = ProcessInfo.processInfo.environment
        return environment.keys.contains { $0.hasPrefix("XCTest") }
    }()
}
