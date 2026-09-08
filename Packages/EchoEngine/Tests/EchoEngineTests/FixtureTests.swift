import Foundation
import Testing

import EchoTestSupport

@Suite struct FixtureLocation {

    @Test func rootSitsAtTheRepositoryRoot() {
        #expect(Fixtures.root.lastPathComponent == "Fixtures")
        // Outside every target: not in the package, not in v1's test folder.
        let path = Fixtures.root.path(percentEncoded: false)
        #expect(!path.contains("/Packages/"))
        #expect(!path.contains("/EchoTests"))
    }

    @Test func channelsResolveInsideTheScenarioFolder() {
        #expect(
            Fixtures.file("double-talk", "mic.wav").path(percentEncoded: false)
                .hasSuffix("/Fixtures/double-talk/mic.wav")
        )
    }

    @Test func anUnrecordedScenarioIsUnavailable() {
        #expect(!Fixtures.available("no-such-scenario"))
    }

    /// Whether or not this machine has fixtures, the failure has to say they are
    /// local-only — the message is the whole point of the resolver.
    @Test func requiringAnUnrecordedScenarioExplainsThatFixturesAreLocalOnly() throws {
        let failure = #expect(throws: FixtureUnavailable.self) {
            try Fixtures.require("no-such-scenario")
        }
        let message = try #require(failure).description
        #expect(message.contains("local-only"))
        #expect(message.contains("Fixtures/README.md"))
    }
}
