//
//  UpdatePrompt.swift
//  Echo
//
//  The one place Echo interrupts: an alert when a newer release exists — at
//  launch, and when the window opens on an Echo that found one since — and
//  the answer to Check for Updates, in the app menu and the menu bar item's.
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
//    2. At most once per version for each launch, and Later means later —
//       the next launch asks again. A newer version found since is offered
//       too: an Echo that runs as a login item can go weeks between launches
//       (product owner, 2026-10-22). Nothing is persisted: a "skip this
//       version" is one more piece of state to own and one more way to get
//       stuck silent.
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

    /// Rule 2: the newest version offered so far. Not persisted and not reset:
    /// the process is the scope.
    private var offeredVersion: ReleaseVersion?

    init(checker: UpdateChecker, installer: UpdateInstaller, session: RecordingSession) {
        self.checker = checker
        self.installer = installer
        self.session = session
    }

    /// The automatic check's answer, at launch and again whenever the window
    /// opens: silent unless there is something it has not offered yet.
    func offerIfAvailable() {
        act(on: decision(asked: false))
    }

    /// The menu bar item's Update to Echo X.Y.Z: the alert's Update, asked
    /// for by name, so it asks nothing more — except during a recording
    /// (rule 3), where it says why it waits.
    func updateNow() {
        guard let release = checker.availableRelease else { return }
        guard !session.phase.isRecording else {
            report(Self.availableTitle(release), Self.waitsForRecording)
            return
        }
        update()
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
    /// `asked` is what separates Check for Updates from the automatic check:
    /// a check the user asked for always answers, and it is not one of the
    /// automatic offers, so the latch neither blocks it nor is checked for it.
    nonisolated static func decide(
        status: UpdateChecker.Status,
        installedVersion: ReleaseVersion?,
        isRecording: Bool,
        offeredVersion: ReleaseVersion?,
        asked: Bool
    ) -> UpdatePromptDecision {
        switch status {
        case .available(let release):
            // Rule 3. An offer that arrives mid-meeting waits for the next
            // one; a check the user asked for still says what it found, and
            // says why it is not offering.
            if isRecording {
                guard asked else { return .sayNothing }
                return .report(title: availableTitle(release), message: waitsForRecording)
            }
            // Rule 2. Nothing is persisted, so the next launch asks again.
            if let offeredVersion, release.version <= offeredVersion, !asked { return .sayNothing }
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
            offeredVersion: offeredVersion,
            asked: asked
        )
    }

    private func act(on decision: UpdatePromptDecision) {
        switch decision {
        case .sayNothing:
            break
        case .offer(let release):
            offeredVersion = release.version
            offer(release)
        case .report(let title, let message):
            report(title, message)
        }
    }

    // MARK: The alerts

    nonisolated static func availableTitle(_ release: LatestRelease) -> String {
        "Echo \(release.version) is available"
    }

    nonisolated static let waitsForRecording = "Updating quits Echo — it can update once this recording stops."

    private func offer(_ release: LatestRelease) {
        let alert = NSAlert()
        alert.messageText = Self.availableTitle(release)
        alert.informativeText = """
            You're on \(Self.installedText(checker.installedVersion)). Updating quits Echo, installs the new \
            version and reopens it. Your meetings are untouched.
            """
        alert.addButton(withTitle: "Update")
        // Esc is Later: NSAlert gives Esc only to a button called Cancel, and
        // every other dialog in Echo answers Esc.
        alert.addButton(withTitle: "Later").keyEquivalent = "\u{1b}"
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
