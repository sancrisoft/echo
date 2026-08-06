//
//  CallSessionMachineTests.swift
//  EchoTests
//
//  SP-006: the island's entire behavior contract, one test per row of the
//  machine's transition table — plus the two non-negotiable product lines as
//  sweeps over every short event sequence:
//
//    • nothing records without an explicit tap, and
//    • no start prompt ever appears over a running recording.
//
//  The Core Audio shim (`MicActivityMonitor`) and the panel stay manual per
//  SP-006's testing decisions; everything decided lives here.
//

import Foundation
import Testing
@testable import Echo

struct CallSessionMachineTests {

    private let zoom = CallApp(displayName: "Zoom", bundlePrefix: "us.zoom.xos")
    private let chrome = CallApp(displayName: "Google Chrome", bundlePrefix: "com.google.Chrome")

    private var promptRetract: TimeInterval { CallDetectionTiming.promptRetract }
    private var savedRetract: TimeInterval { CallDetectionTiming.savedRetract }

    // MARK: - Fixtures

    /// Catalogued capture seen, debounce running, nothing shown yet.
    private func candidateMachine() -> CallSessionMachine {
        var machine = CallSessionMachine()
        machine.handle(.matchedAppsChanged([zoom]))
        return machine
    }

    /// A confirmed call. `recording: true` mirrors a session that was already
    /// running when the call was detected, so no prompt is ever shown.
    private func inCallMachine(recording: Bool = false) -> CallSessionMachine {
        var machine = candidateMachine()
        if recording { machine.handle(.recordingChanged(true)) }
        machine.handle(.debounceFired)
        return machine
    }

    /// A confirmed call with the start prompt on screen.
    private func promptingMachine() -> CallSessionMachine {
        inCallMachine()
    }

    /// A recording whose call just ended: countdown face, grace armed.
    private func endGraceMachine() -> CallSessionMachine {
        var machine = inCallMachine(recording: true)
        machine.handle(.matchedAppsChanged([]))
        return machine
    }

    /// The "Meeting saved" face, after an expired countdown.
    private func savedMachine() -> CallSessionMachine {
        var machine = endGraceMachine()
        machine.handle(.graceFired)
        return machine
    }

    // MARK: - Detection edges (rows 1–3)

    @Test func cataloguedCaptureStartsTheDebounceWithoutShowingAnything() {
        var machine = CallSessionMachine()

        let actions = machine.handle(.matchedAppsChanged([zoom]))

        #expect(actions == [.startDebounceTimer])
        #expect(machine.phase == .candidate)
        #expect(machine.currentApp == zoom)
        #expect(machine.face == nil)
    }

    @Test func blipShorterThanDebounceNeverPrompts() {
        // An app probing the mic (or a device reconfiguration) releases it
        // again before the debounce elapses: no call ever happened.
        var machine = candidateMachine()

        let actions = machine.handle(.matchedAppsChanged([]))

        #expect(actions == [.cancelDebounceTimer])
        #expect(machine.phase == .idle)
        #expect(machine.currentApp == nil)
        // A straggling timer fire after the cancel changes nothing either.
        #expect(machine.handle(.debounceFired).isEmpty)
        #expect(machine.face == nil)
    }

    @Test func setChangeDuringTheDebounceReattributesWithoutRearmingTheTimer() {
        var machine = candidateMachine()

        let actions = machine.handle(.matchedAppsChanged([chrome, zoom]))

        #expect(actions.isEmpty)   // the debounce already runs
        #expect(machine.phase == .candidate)
        #expect(machine.currentApp == chrome)
    }

    // MARK: - Confirming a call (rows 4–5)

    @Test func debounceElapsingShowsTheStartPromptAndArmsTheRetract() {
        var machine = candidateMachine()

        let actions = machine.handle(.debounceFired)

        #expect(actions == [.setFace(.startPrompt(appName: "Zoom", scoped: true)), .startRetractTimer(promptRetract)])
        #expect(machine.phase == .inCall)
        #expect(machine.face == .startPrompt(appName: "Zoom", scoped: true))
        #expect(!machine.keptRecordingLatch)
    }

    @Test func callDetectedWhileAlreadyRecordingShowsNoPrompt() {
        // Rule 5: the island never nags about something the user already did.
        var machine = candidateMachine()
        machine.handle(.recordingChanged(true))

        let actions = machine.handle(.debounceFired)

        #expect(actions.isEmpty)
        #expect(machine.phase == .inCall)
        #expect(machine.face == nil)
    }

    // MARK: - Politeness (rows 6–8)

    @Test func ignoredPromptRetractsToThePill() {
        var machine = promptingMachine()

        let actions = machine.handle(.retractFired)

        #expect(actions == [.setFace(.compactPill)])
        #expect(machine.face == .compactPill)
        #expect(machine.phase == .inCall)
    }

    @Test func pillTapReexpandsThePrompt() {
        var machine = promptingMachine()
        machine.handle(.retractFired)

        let actions = machine.handle(.pillTapped)

        #expect(actions == [.setFace(.startPrompt(appName: "Zoom", scoped: true)), .startRetractTimer(promptRetract)])
        #expect(machine.face == .startPrompt(appName: "Zoom", scoped: true))
    }

    @Test func dismissSilencesTheIslandForTheRestOfTheCall() {
        // Rule 9: "no" means no — for this call.
        var machine = promptingMachine()

        let actions = machine.handle(.dismissTapped)

        #expect(actions == [.cancelRetractTimer, .setFace(nil)])
        #expect(machine.face == nil)
        #expect(machine.dismissedThisCall)
        // Nothing reappears while the call continues.
        #expect(machine.handle(.retractFired).isEmpty)
        #expect(machine.handle(.pillTapped).isEmpty)
        #expect(machine.handle(.matchedAppsChanged([zoom])).isEmpty)
        #expect(machine.face == nil)
    }

    @Test func dismissFromThePillAlsoSilencesTheCall() {
        var machine = promptingMachine()
        machine.handle(.retractFired)

        let actions = machine.handle(.dismissTapped)

        #expect(actions == [.cancelRetractTimer, .setFace(nil)])
        #expect(machine.dismissedThisCall)
    }

    @Test func theNextCallPromptsAgainAfterADismissal() {
        var machine = promptingMachine()
        machine.handle(.dismissTapped)
        machine.handle(.matchedAppsChanged([]))          // call over
        machine.handle(.matchedAppsChanged([zoom]))      // a new call
        #expect(!machine.dismissedThisCall)

        let actions = machine.handle(.debounceFired)

        #expect(actions == [.setFace(.startPrompt(appName: "Zoom", scoped: true)), .startRetractTimer(promptRetract)])
    }

    // MARK: - Starting (rows 9–10)

    @Test func startTapRequestsRecordingExactlyOnce() {
        var machine = promptingMachine()

        let actions = machine.handle(.startTapped)

        #expect(actions == [.cancelRetractTimer, .setFace(nil), .requestStartRecording(.app(zoom))])
        #expect(machine.face == nil)
        // A repeat tap on a face that is already gone requests nothing.
        #expect(machine.handle(.startTapped).isEmpty)
    }

    @Test func startTapScopesToTheAppTheIslandNames() {
        // SP-008: the island's promise is explicit — the button says "Record
        // Zoom" and the tap requests a session scoped to exactly that app.
        var machine = promptingMachine()

        let actions = machine.handle(.startTapped)

        #expect(actions.contains(.requestStartRecording(.app(zoom))))
    }

    @Test func startTapScopesToTheFirstCatalogMatchWhenSeveralAppsCapture() {
        // Two calls overlap: the scope follows the app the island *names* —
        // the first catalog match — never a different member of the set
        // (SP-008 settled decision).
        var machine = CallSessionMachine()
        machine.handle(.matchedAppsChanged([zoom, chrome]))
        machine.handle(.debounceFired)
        #expect(machine.face == .startPrompt(appName: "Zoom", scoped: true))

        let actions = machine.handle(.startTapped)

        #expect(actions == [.cancelRetractTimer, .setFace(nil), .requestStartRecording(.app(zoom))])
    }

    @Test func startTapOnAnUnscopeableAppRequestsAnHonestGlobalRecording() {
        // SP-008 open question 3, resolved: the FaceTime daemon's output
        // audio is not verified scopeable, so the face drops the scope claim
        // (`scoped: false` → the plain "Start recording" button) and the tap
        // requests Everything — copy and capture agree by construction. The
        // real catalog entry is used so the test breaks if the flag flips.
        let daemon = CallAppCatalog.match(bundleID: "com.apple.avconferenced")!
        var machine = CallSessionMachine()
        machine.handle(.matchedAppsChanged([daemon]))

        let confirm = machine.handle(.debounceFired)
        #expect(confirm == [
            .setFace(.startPrompt(appName: "FaceTime", scoped: false)),
            .startRetractTimer(promptRetract),
        ])

        let actions = machine.handle(.startTapped)
        #expect(actions == [.cancelRetractTimer, .setFace(nil), .requestStartRecording(.everything)])
    }

    @Test func manualStartWhileThePromptIsUpHidesItSilently() {
        var machine = promptingMachine()

        let actions = machine.handle(.recordingChanged(true))

        #expect(actions == [.cancelRetractTimer, .setFace(nil)])
        #expect(machine.isRecording)
        #expect(machine.face == nil)
        #expect(machine.phase == .inCall)
    }

    @Test func manualStartWhileThePillIsUpHidesItSilently() {
        var machine = promptingMachine()
        machine.handle(.retractFired)

        #expect(machine.handle(.recordingChanged(true)) == [.cancelRetractTimer, .setFace(nil)])
        #expect(machine.face == nil)
    }

    @Test func theRecordingStartedByTheIslandIsReportedBackWithoutAnyFaceChange() {
        // After `startTapped` the island is already hidden; the controller's
        // observation of `isRecording` must not disturb anything.
        var machine = promptingMachine()
        machine.handle(.startTapped)

        #expect(machine.handle(.recordingChanged(true)).isEmpty)
        #expect(machine.isRecording)
        #expect(machine.face == nil)
    }

    // MARK: - Manual stop mid-call (row 11)

    @Test func manualStopMidCallIsNotRePrompted() {
        // Rule 5: stopping by hand during a call is a decision, not a slip.
        var machine = promptingMachine()
        machine.handle(.startTapped)
        machine.handle(.recordingChanged(true))

        let actions = machine.handle(.recordingChanged(false))

        #expect(actions.isEmpty)
        #expect(!machine.isRecording)
        #expect(machine.dismissedThisCall)
        #expect(machine.phase == .inCall)
        #expect(machine.face == nil)
    }

    // MARK: - Call end (rows 12–14)

    @Test func callEndingWithoutARecordingJustHidesTheIsland() {
        var machine = promptingMachine()

        let actions = machine.handle(.matchedAppsChanged([]))

        #expect(actions == [.cancelRetractTimer, .setFace(nil)])
        #expect(machine.phase == .idle)
        #expect(machine.face == nil)
        #expect(!machine.dismissedThisCall)
    }

    @Test func callEndingWhileRecordingArmsTheGraceCountdown() {
        var machine = inCallMachine(recording: true)

        let actions = machine.handle(.matchedAppsChanged([]))

        #expect(actions == [.setFace(.endGrace(appName: "Zoom")), .startGraceTimer])
        #expect(machine.phase == .endGrace)
        #expect(machine.isRecording)
    }

    @Test func aRecordingStartedBeforeTheCallStillGetsGraceProtection() {
        // Spec story 8 + criterion 4: pressing record before the call connects
        // must not cost the auto-stop that bounds a forgotten session.
        var machine = CallSessionMachine()
        machine.handle(.recordingChanged(true))
        machine.handle(.matchedAppsChanged([zoom]))
        #expect(machine.handle(.debounceFired).isEmpty)      // no prompt (rule 5)

        let actions = machine.handle(.matchedAppsChanged([]))

        #expect(actions == [.setFace(.endGrace(appName: "Zoom")), .startGraceTimer])
    }

    @Test func afterKeepRecordingTheEndedCallRaisesNothingFurther() {
        // Rule 6: the call the user kept recording through is done nagging —
        // duplicate "nothing is capturing" reports and straggling timers can
        // neither resurrect the countdown nor stop the session.
        var machine = endGraceMachine()
        machine.handle(.keepRecordingTapped)

        #expect(machine.handle(.matchedAppsChanged([])).isEmpty)
        #expect(machine.handle(.graceFired).isEmpty)
        #expect(machine.handle(.retractFired).isEmpty)
        #expect(machine.isRecording)
        #expect(machine.face == nil)
    }

    @Test func aNewConfirmedCallClearsTheKeepRecordingLatch() {
        // Rule 6's other half: the suppression covers the call it was pressed
        // in, so the *next* call that starts and ends gets its countdown back.
        var machine = endGraceMachine()
        machine.handle(.keepRecordingTapped)
        #expect(machine.keptRecordingLatch)

        machine.handle(.matchedAppsChanged([zoom]))
        machine.handle(.debounceFired)
        #expect(!machine.keptRecordingLatch, "a newly confirmed call clears the latch")

        let actions = machine.handle(.matchedAppsChanged([]))
        #expect(actions == [.setFace(.endGrace(appName: "Zoom")), .startGraceTimer])
    }

    // MARK: - Grace resolution (rows 15–19)

    @Test func captureResumingInsideTheGraceCancelsTheStopSilently() {
        // Story 4: one flaky reconnect must not split a meeting in two.
        var machine = endGraceMachine()

        let actions = machine.handle(.matchedAppsChanged([zoom]))

        #expect(actions == [.cancelGraceTimer, .setFace(nil)])
        #expect(machine.phase == .inCall)
        #expect(machine.isRecording)
        #expect(machine.face == nil)
        // No re-debounce: recording continuity wins over re-confirmation.
        #expect(machine.handle(.debounceFired).isEmpty)
    }

    @Test func graceExpiryStopsRecordingExactlyOnce() {
        var machine = endGraceMachine()

        let actions = machine.handle(.graceFired)

        #expect(actions == [.requestStopRecording, .setFace(.saved), .startRetractTimer(savedRetract)])
        #expect(machine.phase == .idle)
        #expect(machine.face == .saved)
        // A duplicate expiry (or a late "stop now") cannot stop twice.
        #expect(machine.handle(.graceFired).isEmpty)
        #expect(machine.handle(.stopNowTapped).isEmpty)
    }

    @Test func theStopIsReportedBackWithoutDisturbingTheSavedFace() {
        var machine = savedMachine()

        #expect(machine.handle(.recordingChanged(false)).isEmpty)
        #expect(!machine.isRecording)
        #expect(machine.face == .saved)
    }

    @Test func stopNowStopsImmediately() {
        var machine = endGraceMachine()

        let actions = machine.handle(.stopNowTapped)

        #expect(actions == [
            .cancelGraceTimer,
            .requestStopRecording,
            .setFace(.saved),
            .startRetractTimer(savedRetract),
        ])
        #expect(machine.phase == .idle)
        #expect(machine.face == .saved)
    }

    @Test func keepRecordingCancelsTheStopAndSetsTheLatch() {
        var machine = endGraceMachine()

        let actions = machine.handle(.keepRecordingTapped)

        #expect(actions == [.cancelGraceTimer, .setFace(nil)])
        #expect(machine.phase == .idle)
        #expect(machine.keptRecordingLatch)
        #expect(machine.isRecording, "the automation never overrides the user's intent")
        #expect(machine.face == nil)
    }

    @Test func manualStopDuringTheCountdownCancelsTheAutoStop() {
        // Criterion: a manual stop during the countdown is respected — no
        // double stop, no orphan island.
        var machine = endGraceMachine()

        let actions = machine.handle(.recordingChanged(false))

        #expect(actions == [.cancelGraceTimer, .setFace(nil)])
        #expect(machine.phase == .idle)
        #expect(machine.face == nil)
        #expect(!machine.isRecording)
        // The countdown's own expiry can no longer stop anything.
        #expect(machine.handle(.graceFired).isEmpty)
    }

    // MARK: - Saved face (rows 20–21)

    @Test func savedFaceRetractsOnItsOwn() {
        var machine = savedMachine()

        #expect(machine.handle(.retractFired) == [.setFace(nil)])
        #expect(machine.face == nil)
        #expect(machine.phase == .idle)
    }

    @Test func openEchoOpensTheSavedMeetingAndHidesTheIsland() {
        var machine = savedMachine()

        let actions = machine.handle(.openEchoTapped)

        #expect(actions == [.cancelRetractTimer, .setFace(nil), .openDashboardToSavedMeeting])
        #expect(machine.face == nil)
        // Only the saved face opens the dashboard.
        #expect(machine.handle(.openEchoTapped).isEmpty)
        var prompting = promptingMachine()
        #expect(prompting.handle(.openEchoTapped).isEmpty)
    }

    // MARK: - The setting (rows 22–23)

    @Test func disablingTheSettingTearsDownEverything() {
        // Off means off, mid-call, with the island on screen.
        var machine = promptingMachine()

        let actions = machine.handle(.setEnabled(false))

        #expect(actions == [.cancelDebounceTimer, .cancelRetractTimer, .cancelGraceTimer, .setFace(nil)])
        #expect(!machine.enabled)
        #expect(machine.phase == .idle)
        #expect(machine.face == nil)
        #expect(machine.currentApp == nil)
        #expect(!machine.dismissedThisCall)
        #expect(!machine.keptRecordingLatch)
    }

    @Test func disablingDuringTheCountdownNeverStopsTheRecording() {
        var machine = endGraceMachine()

        let actions = machine.handle(.setEnabled(false))

        #expect(!actions.contains(.requestStopRecording))
        #expect(machine.isRecording)
    }

    @Test func aDisabledMachineIsInert() {
        var machine = CallSessionMachine()
        machine.handle(.setEnabled(false))

        let events: [CallSessionMachine.Event] = [
            .matchedAppsChanged([zoom]), .matchedAppsChanged([]),
            .debounceFired, .retractFired, .graceFired,
            .startTapped, .pillTapped, .dismissTapped,
            .stopNowTapped, .keepRecordingTapped, .openEchoTapped,
            .setEnabled(false),
        ]
        for event in events {
            #expect(machine.handle(event).isEmpty, "disabled machine reacted to \(event)")
        }
        #expect(machine.face == nil)
        #expect(machine.phase == .idle)
    }

    @Test func aDisabledMachineStillTracksTheRecordingState() {
        // So re-enabling starts from reality and can't prompt over a live
        // session (rule 5).
        var machine = CallSessionMachine()
        machine.handle(.setEnabled(false))

        #expect(machine.handle(.recordingChanged(true)).isEmpty)
        #expect(machine.isRecording)

        machine.handle(.setEnabled(true))
        machine.handle(.matchedAppsChanged([zoom]))
        #expect(machine.handle(.debounceFired).isEmpty, "prompted over a recording after re-enabling")
    }

    @Test func reEnablingStartsClean() {
        var machine = promptingMachine()
        machine.handle(.dismissTapped)
        machine.handle(.setEnabled(false))

        #expect(machine.handle(.setEnabled(true)).isEmpty)
        #expect(machine.enabled)
        #expect(machine.phase == .idle)
        #expect(!machine.dismissedThisCall)

        // And detection works again from scratch.
        #expect(machine.handle(.matchedAppsChanged([zoom])) == [.startDebounceTimer])
        #expect(machine.handle(.debounceFired) == [
            .setFace(.startPrompt(appName: "Zoom", scoped: true)),
            .startRetractTimer(promptRetract),
        ])
    }

    @Test func redundantSettingEventsAreIgnored() {
        var machine = CallSessionMachine()
        #expect(machine.handle(.setEnabled(true)).isEmpty)   // already on
        machine.handle(.setEnabled(false))
        #expect(machine.handle(.setEnabled(false)).isEmpty)
    }

    // MARK: - Idle inertness (row 24)

    @Test func recordingChangesWhileIdleAreTrackedOnly() {
        var machine = CallSessionMachine()

        #expect(machine.handle(.recordingChanged(true)).isEmpty)
        #expect(machine.isRecording)
        #expect(machine.handle(.recordingChanged(false)).isEmpty)
        #expect(!machine.isRecording)
        #expect(machine.face == nil)
        #expect(machine.phase == .idle)
    }

    @Test func tapsAndTimersWhileIdleDoNothing() {
        var machine = CallSessionMachine()

        for event in [CallSessionMachine.Event.debounceFired, .retractFired, .graceFired,
                      .startTapped, .pillTapped, .dismissTapped,
                      .stopNowTapped, .keepRecordingTapped, .openEchoTapped] {
            #expect(machine.handle(event).isEmpty, "idle machine reacted to \(event)")
        }
        #expect(machine.face == nil)
    }

    // MARK: - Full journeys

    @Test func happyPathFromDetectionToAutoStop() {
        var machine = CallSessionMachine()
        var actions: [CallSessionMachine.Action] = []

        actions += machine.handle(.matchedAppsChanged([zoom]))
        actions += machine.handle(.debounceFired)
        actions += machine.handle(.startTapped)
        actions += machine.handle(.recordingChanged(true))
        actions += machine.handle(.matchedAppsChanged([]))
        actions += machine.handle(.graceFired)
        actions += machine.handle(.recordingChanged(false))
        actions += machine.handle(.retractFired)

        #expect(actions == [
            .startDebounceTimer,
            .setFace(.startPrompt(appName: "Zoom", scoped: true)), .startRetractTimer(promptRetract),
            .cancelRetractTimer, .setFace(nil), .requestStartRecording(.app(zoom)),
            .setFace(.endGrace(appName: "Zoom")), .startGraceTimer,
            .requestStopRecording, .setFace(.saved), .startRetractTimer(savedRetract),
            .setFace(nil),
        ])
        #expect(machine.phase == .idle)
        #expect(machine.face == nil)
        #expect(!machine.isRecording)
    }

    @Test func ignoredPromptCollapsesAndDisappearsWhenTheCallEnds() {
        var machine = CallSessionMachine()
        machine.handle(.matchedAppsChanged([chrome]))
        machine.handle(.debounceFired)
        #expect(machine.face == .startPrompt(appName: "Google Chrome", scoped: true))

        machine.handle(.retractFired)
        #expect(machine.face == .compactPill)

        let actions = machine.handle(.matchedAppsChanged([]))
        #expect(actions == [.cancelRetractTimer, .setFace(nil)])
        #expect(machine.face == nil)
        #expect(machine.phase == .idle)
    }

    @Test func reconnectMidCallKeepsOneContinuousRecording() {
        var machine = CallSessionMachine()
        machine.handle(.matchedAppsChanged([zoom]))
        machine.handle(.debounceFired)
        machine.handle(.startTapped)
        machine.handle(.recordingChanged(true))

        // Network drop, then rejoin inside the grace.
        machine.handle(.matchedAppsChanged([]))
        let resume = machine.handle(.matchedAppsChanged([zoom]))
        #expect(resume == [.cancelGraceTimer, .setFace(nil)])

        // The real end of the meeting still stops it.
        #expect(machine.handle(.matchedAppsChanged([])) == [
            .setFace(.endGrace(appName: "Zoom")), .startGraceTimer,
        ])
        #expect(machine.handle(.graceFired).contains(.requestStopRecording))
    }

    // MARK: - Global safety sweeps

    /// Every event the machine has except `startTapped` — the sweep's whole
    /// point is that this alphabet cannot produce a recording.
    private var sweepEventsWithoutStartTap: [CallSessionMachine.Event] {
        [
            .matchedAppsChanged([zoom]),
            .matchedAppsChanged([]),
            .debounceFired,
            .retractFired,
            .graceFired,
            .recordingChanged(true),
            .recordingChanged(false),
            .pillTapped,
            .dismissTapped,
            .stopNowTapped,
            .keepRecordingTapped,
            .openEchoTapped,
            .setEnabled(false),
            .setEnabled(true),
        ]
    }

    private func sequences(of events: [CallSessionMachine.Event], length: Int) -> [[CallSessionMachine.Event]] {
        var sequences: [[CallSessionMachine.Event]] = [[]]
        for _ in 0..<length {
            sequences = sequences.flatMap { prefix in events.map { prefix + [$0] } }
        }
        return sequences
    }

    /// SP-006 success criterion: "no code path in this feature starts capture
    /// on detection alone", made structural — detection, timers, recording
    /// changes, the setting and every other tap, in every order, never ask for
    /// a recording.
    @Test func noSequenceWithoutAStartTapEverRequestsRecording() {
        for sequence in sequences(of: sweepEventsWithoutStartTap, length: 4) {
            var machine = CallSessionMachine()
            for event in sequence {
                let requestedStart = machine.handle(event).contains {
                    if case .requestStartRecording = $0 { return true }
                    return false
                }
                #expect(!requestedStart, "recording requested without a tap: \(sequence)")
            }
        }
    }

    /// The suppression rules as invariants rather than view conditionals: a
    /// start prompt never appears over a running recording or while the feature
    /// is off, the machine's `face` always equals the last face it emitted, and
    /// a stop is only ever requested while a recording is believed to run.
    @Test func facesNeverContradictTheRecordingStateOrTheSetting() {
        let events = sweepEventsWithoutStartTap + [.startTapped]
        for sequence in sequences(of: events, length: 4) {
            var machine = CallSessionMachine()
            var lastFace: IslandFace?
            for event in sequence {
                let actions = machine.handle(event)
                for action in actions {
                    switch action {
                    case .setFace(let face):
                        lastFace = face
                        if case .startPrompt = face {
                            #expect(!machine.isRecording, "prompted over a recording: \(sequence)")
                        }
                        #expect(machine.enabled || face == nil, "face shown while disabled: \(sequence)")
                    case .requestStopRecording:
                        #expect(machine.isRecording, "stop requested with nothing recording: \(sequence)")
                    case .requestStartRecording:
                        #expect(!machine.isRecording, "start requested while recording: \(sequence)")
                    default:
                        break
                    }
                }
                #expect(machine.face == lastFace, "machine face out of step with the panel: \(sequence)")
                if !machine.enabled {
                    #expect(machine.face == nil, "island visible while disabled: \(sequence)")
                }
            }
        }
    }
}
