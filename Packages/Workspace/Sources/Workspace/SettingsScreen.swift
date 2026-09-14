//
//  SettingsScreen.swift
//  Workspace
//
//  The settings that exist for the library: launch at login, recordings,
//  summaries, updates, storage. Sections for call detection and models arrive
//  with the packages that own them. Launch at login reads `SMAppService`, the
//  OS's own answer, and is never mirrored into `settings.json`: the user can
//  change login items in System Settings behind our back.
//

import DesignSystem
import EchoCore
import Meetings
import Recording
import ServiceManagement
import SwiftUI
import Updates

struct SettingsScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingLibrary.self) private var library
    @Environment(RecordingSession.self) private var session
    @Environment(UpdateChecker.self) private var updates

    let dataRoot: DataRoot

    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?
    @State private var confirmDeleteRecordings = false
    @State private var confirmEmptyTrash = false

    /// Shown under the update buttons when the updater could not be started,
    /// with the command to paste instead. This run's problem only: the report
    /// a previous failed update left behind belongs to `UpdateChecker`.
    @State private var updateActionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(EchoFont.documentTitle)
                .foregroundStyle(EchoColor.textPrimary)
                .padding(.horizontal, EchoSpacing.xl)
                .padding(.vertical, EchoSpacing.l)
            Divider()
            Form {
                general
                recordings
                summaries
                updatesSection
                storage
                about
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: EchoLayout.readingWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            readLaunchAtLogin()
            library.measureStorage()
        }
        .confirmationDialog(
            "Delete all saved recordings?", isPresented: $confirmDeleteRecordings, titleVisibility: .visible
        ) {
            Button("Delete Recordings", role: .destructive) {
                Task { await library.deleteAllPreservedAudio() }
            }
        } message: {
            Text("Transcripts and notes stay. Only the audio files kept after transcription are removed.")
        }
        .confirmationDialog("Empty Trash?", isPresented: $confirmEmptyTrash, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) {
                Task { await library.emptyTrash() }
            }
        } message: {
            Text(
                "All \(library.trashedMetas.count) meetings in Trash are removed from this Mac. This cannot be undone.")
        }
    }

    // MARK: Sections

    private var general: some View {
        Section("General") {
            // A closure, not the method reference: passing the isolated method
            // directly crashes the Swift 6.3 compiler in IRGen.
            Toggle("Launch Echo at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(EchoFont.micro)
                    .foregroundStyle(EchoColor.danger)
            }
        }
    }

    private var recordings: some View {
        Section {
            Toggle(
                "Keep audio recordings after transcription",
                isOn: Binding(
                    get: { settings.keepRecordingsAfterTranscription },
                    set: { settings.setKeepRecordings(enabled: $0) }
                )
            )
            HStack {
                Text(recordingsSummary)
                    .foregroundStyle(EchoColor.textSecondary)
                Spacer()
                Button("Delete All Saved Recordings…") { confirmDeleteRecordings = true }
                    .buttonStyle(.echoDestructive)
                    .disabled((library.storage?.recordingsCount ?? 0) == 0)
            }
        } header: {
            Text("Recordings")
        } footer: {
            Text("Turning this off never deletes recordings already saved; remove them here or per meeting.")
        }
    }

    private var summaries: some View {
        Section {
            Toggle(
                "Generate summaries automatically",
                isOn: Binding(
                    get: { settings.autoGenerateSummaries },
                    set: { settings.setAutoGenerateSummaries(enabled: $0) }
                )
            )
        } header: {
            Text("Summaries")
        } footer: {
            Text("Notes are written on this Mac after each recording. Off still allows a manual “Generate summary”.")
        }
    }

    private var updatesSection: some View {
        Section {
            LabeledContent("Version", value: AppIdentity.version.display)

            HStack(alignment: .firstTextBaseline, spacing: EchoSpacing.m) {
                VStack(alignment: .leading, spacing: EchoSpacing.xxs) {
                    Text(updateStatusText)
                    if let checked = updates.lastCheckedAt {
                        Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                            .font(EchoFont.micro)
                            .foregroundStyle(EchoColor.textTertiary)
                    }
                }
                Spacer()
                Button(updates.isChecking ? "Checking…" : "Check for Updates") {
                    Task { await updates.check() }
                }
                .buttonStyle(.echoSecondary)
                .disabled(updates.isChecking)
            }

            if let release = updates.availableRelease {
                HStack(spacing: EchoSpacing.s) {
                    // Updating quits Echo; a recording in progress would be
                    // lost, so the button waits for it to stop.
                    Button("Update Now") { updateNow() }
                        .buttonStyle(.echoPrimary)
                        .disabled(session.phase.isRecording)
                    Button("View Release Notes") { UpdateInstaller.openReleasePage(release) }
                        .buttonStyle(.echoSecondary)
                }
                if session.phase.isRecording {
                    Text("Updating quits Echo — it can update once this recording stops.")
                        .font(EchoFont.micro)
                        .foregroundStyle(EchoColor.textSecondary)
                }
            }

            // Either this run's failure to start the updater, or the report a
            // failed update left behind before Echo reopened.
            if let problem = updateActionError ?? updates.lastInstallFailure {
                Text(problem)
                    .font(EchoFont.micro)
                    .foregroundStyle(EchoColor.warning)
                    .textSelection(.enabled)
            }

            // A closure, not the method reference: passing the isolated method
            // directly crashes the Swift 6.3 compiler in IRGen.
            Toggle(
                "Check for updates automatically",
                isOn: Binding(
                    get: { settings.checkForUpdatesAutomatically },
                    set: { setAutomaticUpdateChecks($0) }
                )
            )
        } header: {
            Text("Updates")
        } footer: {
            Text(
                """
                Echo asks GitHub once a day whether a newer release exists. That request carries Echo's version \
                and nothing about you or your meetings. Update Now quits Echo, runs the same install script as \
                the README, and reopens Echo on the new version; if anything fails, the Echo you had reopens \
                and the reason shows here.
                """
            )
        }
    }

    private var storage: some View {
        Section {
            storageRow("Meetings", library.storage?.meetingsBytes)
            storageRow("Saved recordings", library.storage?.recordingsBytes)
            storageRow("Trash", library.storage?.trashBytes)
            storageRow("AI models", library.storage?.modelsBytes)
            HStack {
                Button("Empty Trash…") { confirmEmptyTrash = true }
                    .buttonStyle(.echoDestructive)
                    .disabled(library.trashedMetas.isEmpty)
                Button("Reveal Data Folder in Finder") { MeetingActions.revealInFinder(dataRoot.url) }
                    .buttonStyle(.echoSecondary)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Everything Echo keeps lives in one folder. Deleting Echo and that folder removes all of it.")
        }
    }

    private var about: some View {
        Section("About") {
            LabeledContent("Version", value: AppIdentity.version.display)
            Text("Audio, transcripts and notes stay on this Mac. Nothing is uploaded anywhere.")
                .font(EchoFont.control)
                .foregroundStyle(EchoColor.textSecondary)
        }
    }

    // MARK: Helpers

    private var updateStatusText: String {
        switch updates.status {
        case .idle:
            return updates.isChecking ? "Checking GitHub…" : "Echo checks GitHub's releases for newer versions."
        case .upToDate:
            return "You're up to date."
        case .available(let release):
            var text = "Echo \(release.version) is available"
            if let published = release.publishedAt {
                text += ", released \(published.formatted(.relative(presentation: .named)))"
            }
            return text + "."
        case .failed(let message):
            return message
        }
    }

    /// Returns only if the updater could not be started; otherwise Echo quits
    /// here and the updater reopens it. The installer is a value over the data
    /// root, not state: building one at the click is the same shape as
    /// `MeetingActions.revealInFinder`.
    private func updateNow() {
        do {
            try UpdateInstaller(dataRoot: dataRoot).updateAndRelaunch()
        } catch {
            ErrorTrace.record("Starting the updater failed", error: error, category: "Updates")
            updateActionError = "\(error). Paste this into a terminal instead:  \(GitHubReleaseFeed.installCommand)"
        }
    }

    private func setAutomaticUpdateChecks(_ enabled: Bool) {
        settings.setCheckForUpdates(automatically: enabled)
        // Turning it on is a request for an answer; give one now instead of at
        // the next daily tick.
        if enabled, updates.lastCheckedAt == nil {
            Task { await updates.check() }
        }
    }

    private func storageRow(_ title: String, _ bytes: Int64?) -> some View {
        LabeledContent(title) {
            Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…")
                .monospacedDigit()
                .foregroundStyle(EchoColor.textSecondary)
        }
    }

    private var recordingsSummary: String {
        guard let storage = library.storage else { return "Calculating…" }
        guard storage.recordingsCount > 0 else { return "No saved recordings." }
        let size = ByteCountFormatter.string(fromByteCount: storage.recordingsBytes, countStyle: .file)
        return "\(storage.recordingsCount) saved · \(size)"
    }

    private func readLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            ErrorTrace.record("Changing launch at login failed", error: error, category: "Settings")
        }
        readLaunchAtLogin()
    }
}
