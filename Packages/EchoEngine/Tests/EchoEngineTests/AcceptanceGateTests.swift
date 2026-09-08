import Testing

@testable import EchoTestSupport

@Suite struct AcceptanceGateSpelling {

    @Test func swiftTestSpellsItWithoutThePrefix() {
        #expect(Acceptance.isEnabled(in: ["ECHO_ACCEPTANCE": "1"]))
    }

    @Test func xcodebuildSpellsItWithThePrefix() {
        #expect(Acceptance.isEnabled(in: ["TEST_RUNNER_ECHO_ACCEPTANCE": "1"]))
    }

    @Test(arguments: [[:], ["ECHO_ACCEPTANCE": "0"], ["ECHO_ACCEPTANCE": "yes"]])
    func theGateIsClosedByDefault(environment: [String: String]) {
        #expect(!Acceptance.isEnabled(in: environment))
    }
}

/// The proof that the trait skips rather than fails: with the gate closed this
/// suite never runs, and the run reports it as skipped with the reason.
@Suite(.acceptance) struct AcceptanceGatedProbe {

    @Test func neverRunsWithTheGateClosed() {
        #expect(Acceptance.isEnabled)
    }
}
