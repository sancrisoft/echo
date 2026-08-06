//
//  TestHostGuardTests.swift
//  EchoTests
//
//  The one empirical check the test-host guard cannot do without: this suite
//  runs HOSTED inside the real Echo.app, so `TestHost.isActive` being true
//  here proves detection works for the exact configuration this project
//  ships (a Swift Testing bundle injected into the app). If this ever fails,
//  the host app is booting its full production launch path against the real
//  data folder during every test run — the two-instance store corruption
//  TestHostGuard.swift exists to prevent.
//

import Testing
@testable import Echo

struct TestHostGuardTests {

    @Test("the hosted test process is detected as a test host")
    func detectsHostedTestRun() {
        #expect(TestHost.isActive)
    }
}
