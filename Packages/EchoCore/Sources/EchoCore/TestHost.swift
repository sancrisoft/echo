//
//  TestHost.swift
//  EchoCore
//
//  Detects when this process is a unit-test HOST, so the composition root can
//  skip every launch side effect.
//
//  Why this exists: `xcodebuild test` launches the real Echo.app as the test
//  host, and in the PoC that host once booted the full production launch path
//  against the real data folder while a real Echo was recording; a test run's
//  sweep deleted a live meeting's meta.json. Under a test host the app must be
//  inert scaffolding: tests construct their own objects against temporary
//  roots. In v2 this flag is read in exactly one place — `AppComposition.start`
//  — because initializers never perform side effects.
//

import Foundation

public enum TestHost {

    /// True when this process is the test runner's host app rather than a real
    /// user launch. Belt and braces, because a false negative corrupts the
    /// user's real store while a false positive merely skips warm-up in a
    /// debug run:
    ///
    /// * `NSClassFromString("XCTestCase")` — the XCTest runtime is linked into
    ///   the host for both XCTest and Swift Testing bundles.
    /// * The `XCTest*` environment keys Xcode sets on the host process.
    ///
    /// Computed exactly once: the answer can never change mid-process.
    public static let isActive: Bool = {
        if NSClassFromString("XCTestCase") != nil { return true }
        let environment = ProcessInfo.processInfo.environment
        return environment.keys.contains { $0.hasPrefix("XCTest") }
    }()
}
