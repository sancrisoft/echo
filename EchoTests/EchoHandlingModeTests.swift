//
//  EchoHandlingModeTests.swift
//  EchoTests
//

import Testing
@testable import Echo

struct EchoHandlingModeTests {

    @Test(arguments: [
        (OutputRouteClass.builtInSpeakers, EchoHandlingMode.cancelling),
        (OutputRouteClass.headphones, EchoHandlingMode.bypassed),
        (OutputRouteClass.unsupported, EchoHandlingMode.dedupOnly),
    ])
    func initialModeFollowsInitialRoute(route: OutputRouteClass, expected: EchoHandlingMode) {
        let machine = EchoModeMachine(initialRoute: route)
        #expect(machine.mode == expected)
    }

    @Test(arguments: [
        // Cancelling ↔ Bypassed (headphones connected / disconnected)
        (OutputRouteClass.builtInSpeakers, OutputRouteClass.headphones, EchoHandlingMode.bypassed),
        (OutputRouteClass.headphones, OutputRouteClass.builtInSpeakers, EchoHandlingMode.cancelling),
        // Cancelling ↔ DedupOnly
        (OutputRouteClass.builtInSpeakers, OutputRouteClass.unsupported, EchoHandlingMode.dedupOnly),
        (OutputRouteClass.unsupported, OutputRouteClass.builtInSpeakers, EchoHandlingMode.cancelling),
        // Bypassed ↔ DedupOnly
        (OutputRouteClass.headphones, OutputRouteClass.unsupported, EchoHandlingMode.dedupOnly),
        (OutputRouteClass.unsupported, OutputRouteClass.headphones, EchoHandlingMode.bypassed),
        // Same-route events are no-ops
        (OutputRouteClass.builtInSpeakers, OutputRouteClass.builtInSpeakers, EchoHandlingMode.cancelling),
        (OutputRouteClass.headphones, OutputRouteClass.headphones, EchoHandlingMode.bypassed),
        (OutputRouteClass.unsupported, OutputRouteClass.unsupported, EchoHandlingMode.dedupOnly),
    ])
    func routeChangesFollowStateDiagram(
        initialRoute: OutputRouteClass,
        newRoute: OutputRouteClass,
        expected: EchoHandlingMode
    ) {
        var machine = EchoModeMachine(initialRoute: initialRoute)
        machine.handle(.routeChanged(newRoute))
        #expect(machine.mode == expected)
    }

    @Test func engineFailureWhileCancellingDegradesAndFiresNoticeOnce() {
        var machine = EchoModeMachine(initialRoute: .builtInSpeakers)

        let effect = machine.handle(.engineFailed)
        #expect(machine.mode == .degraded)
        #expect(effect == .showDegradationNotice)

        // Repeated failure events within the same episode must not re-fire.
        let repeated = machine.handle(.engineFailed)
        #expect(machine.mode == .degraded)
        #expect(repeated == nil)
    }

    @Test func recoveryReturnsToCancellingAndClearsNotice() {
        var machine = EchoModeMachine(initialRoute: .builtInSpeakers)
        machine.handle(.engineFailed)

        let effect = machine.handle(.engineRecovered)
        #expect(machine.mode == .cancelling)
        #expect(effect == .clearDegradationNotice)

        // Recovery ends the episode: a later failure is a new one and notices again.
        let nextEpisode = machine.handle(.engineFailed)
        #expect(nextEpisode == .showDegradationNotice)
    }

    @Test func routeChangeAwayFromLoudspeakersWhileDegradedEndsTheEpisode() {
        var machine = EchoModeMachine(initialRoute: .builtInSpeakers)
        machine.handle(.engineFailed)

        let effect = machine.handle(.routeChanged(.headphones))
        #expect(machine.mode == .bypassed)
        #expect(effect == .clearDegradationNotice)
    }

    @Test func routeChangeToUnsupportedWhileDegradedEndsTheEpisode() {
        var machine = EchoModeMachine(initialRoute: .builtInSpeakers)
        machine.handle(.engineFailed)

        let effect = machine.handle(.routeChanged(.unsupported))
        #expect(machine.mode == .dedupOnly)
        #expect(effect == .clearDegradationNotice)
    }

    @Test func loudspeakerRouteEventWhileDegradedIsNotARecovery() {
        var machine = EchoModeMachine(initialRoute: .builtInSpeakers)
        machine.handle(.engineFailed)

        // The engine is still down; only `engineRecovered` re-engages
        // cancellation. Route flapping within the episode must not re-notice.
        let effect = machine.handle(.routeChanged(.builtInSpeakers))
        #expect(machine.mode == .degraded)
        #expect(effect == nil)
    }

    @Test(arguments: [OutputRouteClass.headphones, OutputRouteClass.unsupported])
    func engineEventsAreIgnoredOffTheLoudspeakerRoute(route: OutputRouteClass) {
        var machine = EchoModeMachine(initialRoute: route)
        let initialMode = machine.mode

        #expect(machine.handle(.engineFailed) == nil)
        #expect(machine.mode == initialMode)
        #expect(machine.handle(.engineRecovered) == nil)
        #expect(machine.mode == initialMode)
    }

    /// SP-001 US-8: no event sequence may ever stop, fail, or lose a recording.
    /// The machine's `Effect` type models nothing but the degradation notice,
    /// so a stop outcome is unrepresentable; this sweep additionally verifies
    /// that every event sequence lands in a valid mode and that notices never
    /// spam (a show is always followed by a clear before the next show).
    @Test func noEventSequenceStopsARecordingOrSpamsNotices() {
        let events: [EchoModeMachine.Event] = [
            .routeChanged(.builtInSpeakers),
            .routeChanged(.headphones),
            .routeChanged(.unsupported),
            .engineFailed,
            .engineRecovered,
        ]
        let initialRoutes: [OutputRouteClass] = [.builtInSpeakers, .headphones, .unsupported]

        for initialRoute in initialRoutes {
            var sequences: [[EchoModeMachine.Event]] = [[]]
            for _ in 0..<4 {
                sequences = sequences.flatMap { prefix in events.map { prefix + [$0] } }
            }

            for sequence in sequences {
                var machine = EchoModeMachine(initialRoute: initialRoute)
                var noticeShowing = false
                for event in sequence {
                    switch machine.handle(event) {
                    case .showDegradationNotice:
                        #expect(!noticeShowing, "notice re-fired within an episode: \(sequence)")
                        noticeShowing = true
                    case .clearDegradationNotice:
                        #expect(noticeShowing, "clear without a preceding show: \(sequence)")
                        noticeShowing = false
                    case nil:
                        break
                    }
                    #expect([.cancelling, .bypassed, .dedupOnly, .degraded].contains(machine.mode))
                }
            }
        }
    }
}
