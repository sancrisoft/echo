import Testing

import EchoCore
import EchoTestSupport
@testable import EchoV2

/// The one thing the engine package tests cannot prove: loaded into EchoV2.app as
/// the test host, the guard fires and the launch seam does nothing.
@Suite struct TestHostGuardInTheHostedApp {

    @Test func theHostedContextIsDetected() {
        #expect(TestHost.isActive)
    }

    @Test func theLaunchSeamSkipsItsStartupWork() {
        #expect(EchoV2Launch.start() == .skippedForTestHost)
    }
}

/// The gate under the other runner. `xcodebuild` strips the `TEST_RUNNER_`
/// prefix, so this suite opens on `TEST_RUNNER_ECHO_ACCEPTANCE=1` while the same
/// trait opens on `ECHO_ACCEPTANCE=1` under `swift test` — the one spelling
/// difference a package test cannot cover.
@Suite(.acceptance) struct AcceptanceGateUnderXcodebuild {

    @Test func neverRunsWithTheGateClosed() {
        #expect(Acceptance.isEnabled)
    }
}
