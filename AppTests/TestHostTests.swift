//
//  TestHostTests.swift
//  AppTests
//
//  The one empirical check that the host guard works for the shipped
//  configuration: this bundle is injected into the real Echo.app, so inside it
//  `TestHost.isActive` must be true. If this ever fails, the composition root
//  is starting the full launch path against the real data folder during every
//  hosted test run (ADR-004).
//

import EchoCore
import Testing

@Suite("Test host")
struct TestHostTests {

    @Test("the hosted test bundle is detected as a test host")
    func hostIsDetected() {
        #expect(TestHost.isActive)
    }
}
