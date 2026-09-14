//
//  UpdatePrompt.swift
//  Echo
//
//  The one place Echo interrupts: an alert at launch when a newer release
//  exists, and the answer to the app menu's Check for Updates.
//
//  It lives in the app target rather than in `Workspace`, which would need a
//  window that may not be open, or in `Updates`, whose AppKit allowlist entry
//  is for process work and not for drawing.
//
//  Four rules v1 never had to write down, because v1 never interrupts — it
//  waits for you to open Settings and look:
//
//    1. It has to be seen. Echo is an LSUIElement agent sitting at
//       `.accessory` with no window open, so an alert it raises appears behind
//       whatever is frontmost.
//    2. At most one per launch, and Later means later — the next launch asks
//       again. Nothing is persisted: a "skip this version" is one more piece
//       of state to own and one more way to get stuck silent.
//    3. Never while recording. Updating quits Echo, and mid-meeting that is a
//       lost meeting.
//    4. A check you asked for always answers. The automatic one is silent when
//       there is nothing new; this one reports either way.
//

import AppKit
import EchoCore
import Recording
import Updates

/// What the prompt should do about a check's answer.
///
/// The three cases are the whole of rules 2 to 4, and they are a value rather
/// than a branch inside `runModal` because an alert cannot be clicked from a
/// test: stated here, the rules can be swept without a modal run loop.
enum UpdatePromptDecision: Equatable {

    /// Say nothing. The automatic check's usual outcome.
    case sayNothing

    /// Offer the update, with Later beside it.
    case offer(LatestRelease)

    /// Answer a question the user asked and cannot act on right now.
    case report(title: String, message: String)
}

@MainActor
final class UpdatePrompt {

    private let checker: UpdateChecker
    private let installer: UpdateInstaller
    private let session: RecordingSession

    /// Rule 2. Not persisted and not reset: the process is the scope.
    private var offeredThisLaunch = false

    init(checker: UpdateChecker, installer: UpdateInstaller, session: RecordingSession) {
        self.checker = checker
        self.installer = installer
        self.session = session
    }

    /// The launch check's answer: silent unless there is something to offer.
    func offerIfAvailable() {
        act(on: decision(asked: false))
    }

    /// The app menu's Check for Updates. Rule 4: it reports whatever it finds,
    /// "You're up to date" and "Couldn't reach GitHub" included.
    func checkAndReport() async {
        await checker.check()
        act(on: decision(asked: true))
    }

    // MARK: The rules

    /// Rules 2, 3 and 4, as one function of the answer and the moment.
    ///
    /// `asked` is what separates the app menu's check from the automatic one:
    /// a check the user asked for always answers, and it is not the launch's
    /// one interruption, so the latch neither blocks it nor is checked for it.
    nonisolated static func decide(
        status: UpdateChecker.Status,
        installedVersion: ReleaseVersion?,
        isRecording: Bool,
        alreadyOffered: Bool,
        asked: Bool
    ) -> UpdatePromptDecision {
        switch status {
        case .available(let release):
            // Rule 3. An offer that arrives mid-meeting waits for the next
            // launch; a check the user asked for still says what it found,
            // and says why it is not offering.
            if isRecording {
                guard asked else { return .sayNothing }
                return .report(
                    title: "Echo \(release.version) is available",
                    message: "Updating quits Echo — it can update once this recording stops."
                )
            }
            // Rule 2. Nothing is persisted, so the next launch asks again.
            if alreadyOffered, !asked { return .sayNothing }
            return .offer(release)
        case .upToDate:
            guard asked else { return .sayNothing }
            return .report(
                title: "You're up to date.",
                message: "\(installedText(installedVersion)) is the newest release."
            )
        case .failed(let message):
            guard asked else { return .sayNothing }
            return .report(title: "Couldn't check for updates", message: message)
        case .idle:
            // A check always leaves an answer behind; this is the state
            // before the first one.
            return .sayNothing
        }
    }

    private func decision(asked: Bool) -> UpdatePromptDecision {
        Self.decide(
            status: checker.status,
            installedVersion: checker.installedVersion,
            isRecording: session.phase.isRecording,
            alreadyOffered: offeredThisLaunch,
            asked: asked
        )
    }

    private func act(on decision: UpdatePromptDecision) {
        switch decision {
        case .sayNothing:
            break
        case .offer(let release):
            offeredThisLaunch = true
            offer(release)
        case .report(let title, let message):
            report(title, message)
        }
    }

    // MARK: The alerts

    private func offer(_ release: LatestRelease) {
        let alert = NSAlert()
        alert.messageText = "Echo \(release.version) is available"
        alert.informativeText = """
            You're on \(Self.installedText(checker.installedVersion)). Updating quits Echo, installs the new \
            version and reopens it. Your meetings are untouched.
            """
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        guard run(alert) == .alertFirstButtonReturn else { return }
        update()
    }

    /// Returns only if the updater could not be started; otherwise Echo quits
    /// inside this call and the updater reopens it.
    private func update() {
        do {
            try installer.updateAndRelaunch()
        } catch {
            ErrorTrace.record("Starting the updater failed", error: error, category: "Updates")
            report(
                "Couldn't start the updater",
                "\(error)\n\nPaste this into a terminal instead:\n\(GitHubReleaseFeed.installCommand)"
            )
        }
    }

    private func report(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = run(alert)
    }

    /// Rule 1: the same `activate(ignoringOtherApps:)` the activation policy
    /// performs when it promotes. Without it an agent app's alert opens behind
    /// whatever the user was actually looking at.
    private func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    /// What this build compares against, which under `ECHO_INSTALLED_VERSION`
    /// is not what the bundle says.
    nonisolated private static func installedText(_ version: ReleaseVersion?) -> String {
        version.map { "Echo \($0)" } ?? "This build"
    }
}
