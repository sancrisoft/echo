//
//  SettingsView.swift
//  Echo
//
//  The one settings surface, hosted twice: the native `Settings` scene
//  (Cmd+, and the menu-bar gear) and the dashboard sidebar's Settings row
//  (embedded in the detail pane). Same view, same `AppSettings` object —
//  no second source of truth.
//
//  Sections light up with their backends: Call Detection / Recordings /
//  Summaries bind straight to `AppSettings`; General (launch at login) and
//  Storage land with their slices; Updates reads `UpdateChecker` and hands
//  off to the install script for the update itself.
//

import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(RecordingController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @Environment(UpdateChecker.self) private var updates

    /// Launch-at-login state lives in the OS (`SMAppService` is the source
    /// of truth — the §0 exception): read on appearance, re-read after every
    /// change, never mirrored into settings.json.
    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?

    /// Saved-recordings totals for the Delete All button's honest label.
    @State private var savedRecordingsCount = 0
    @State private var savedRecordingsBytes: Int64 = 0
    @State private var confirmDeleteAllRecordings = false
    @State private var confirmEmptyTrash = false

    /// Shown under the update buttons when the updater could not be started,
    /// with the command to paste instead.
    @State private var updateActionError: String?

    var body: some View {
        Form {
            generalSection
            updatesSection
            callDetectionSection
            recordingsSection
            summariesSection
            storageSection
        }
        .formStyle(.grouped)
        .task {
            // The user can change login items in System Settings behind our
            // back — re-read whenever the page appears.
            launchAtLogin = SMAppService.mainApp.status == .enabled
            controller.library.refreshStorageBreakdown()
            await refreshRecordingTotals()
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section {
            Toggle("Launch Echo at login", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            if let launchAtLoginError {
                Label(launchAtLoginError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("General")
        } footer: {
            Text("Echo starts in the menu bar when you log in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Registers/unregisters with `SMAppService`, surfaces a failure inline
    /// (and traces it), and re-reads the real status so the toggle never lies.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            ErrorTrace.record(
                "Changing launch-at-login failed",
                error: error,
                category: "SettingsView",
                metadata: ["requested": enabled ? "on" : "off"]
            )
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Updates

    private var updatesSection: some View {
        Section {
            LabeledContent("Version", value: AppVersion.display)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(updateStatusText)
                    if let checked = updates.lastCheckedAt {
                        Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button(updates.isChecking ? "Checking…" : "Check for Updates") {
                    Task { await updates.check() }
                }
                .disabled(updates.isChecking)
            }

            if let release = updates.availableRelease {
                HStack(spacing: 10) {
                    // Updating quits Echo; a recording in progress would be
                    // lost, so the button waits for it to stop.
                    Button("Update Now") { updateNow() }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.isRecording)
                    Button("View Release Notes") { UpdateActions.openReleasePage(release) }
                }
                if controller.isRecording {
                    Text("Updating quits Echo — it can update once this recording stops.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Either this run's failure to start the updater, or the report a
            // failed update left behind before Echo reopened.
            if let problem = updateActionError ?? updates.lastInstallFailure {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            Toggle("Check for updates automatically", isOn: Binding(
                get: { settings.checkForUpdatesAutomatically },
                set: { enabled in
                    settings.setCheckForUpdates(automatically: enabled)
                    // Turning it on is a request for an answer; give one now
                    // instead of at the next daily tick.
                    if enabled, updates.lastCheckedAt == nil {
                        Task { await updates.check() }
                    }
                }
            ))
        } header: {
            Text("Updates")
        } footer: {
            Text("Echo asks GitHub once a day whether a newer release exists. That request carries Echo's version and nothing about you or your meetings. Update Now quits Echo, runs the same install script as the README, and reopens Echo on the new version; if anything fails, the Echo you had reopens and the reason shows here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

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
    /// here and the updater reopens it.
    private func updateNow() {
        do {
            try UpdateActions.updateAndRelaunch()
        } catch {
            ErrorTrace.record("Starting the updater failed", error: error, category: "Updates")
            updateActionError = "\(error). Paste this into a terminal instead:  \(GitHubReleaseFeed.installCommand)"
        }
    }

    // MARK: - Call Detection

    private var callDetectionSection: some View {
        Section {
            // The same field the popover's toggle edits (SP-006): flipping it
            // in either place reflects in both instantly.
            Toggle("Suggest recording when a call starts", isOn: Binding(
                get: { settings.callDetectionEnabled },
                set: { settings.setCallDetection(enabled: $0) }
            ))

            // One row per unique app name (a name owning several bundle
            // prefixes appears once and covers all of them), followed by every
            // browser installed on this Mac — the browser tier detection uses,
            // so anything that can raise the island has a checkbox here.
            // Greyed out — not hidden — while the master is off.
            ForEach(detectableAppNames, id: \.self) { name in
                Toggle(name, isOn: Binding(
                    get: { !settings.disabledCallApps.contains(name) },
                    set: { settings.setCallApp(name, enabled: $0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(!settings.callDetectionEnabled)
            }
        } header: {
            Text("Call Detection")
        } footer: {
            Text("Echo watches these apps for microphone use and offers to record. Every browser you have installed is listed, because calls like Google Meet run in them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Every app that can raise the island: the curated catalog plus the
    /// installed browsers. Read through `BrowserCatalog`'s cache, so a
    /// re-render costs nothing and a browser installed while Settings is open
    /// appears on the next one.
    private var detectableAppNames: [String] {
        CallAppCatalog.detectableDisplayNames(browsers: BrowserCatalog.installed())
    }

    // MARK: - Recordings

    private var recordingsSection: some View {
        Section {
            Toggle("Keep audio recordings after transcription", isOn: Binding(
                get: { settings.keepRecordingsAfterTranscription },
                set: { settings.setKeepRecordings(enabled: $0) }
            ))

            // Space is reclaimed only through explicit actions (§2.2): the
            // label carries the honest count + size, and the button is inert
            // while there is nothing to delete.
            Button(role: .destructive) {
                confirmDeleteAllRecordings = true
            } label: {
                Text(deleteAllRecordingsLabel)
            }
            .disabled(savedRecordingsCount == 0)
            .confirmationDialog(
                "Delete all saved recordings?",
                isPresented: $confirmDeleteAllRecordings
            ) {
                Button("Delete All Recordings", role: .destructive) { deleteAllRecordings() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The saved audio of \(savedRecordingsCount) meeting\(savedRecordingsCount == 1 ? "" : "s") (\(byteText(savedRecordingsBytes))) will be deleted. Transcripts and summaries stay. This cannot be undone.")
            }
        } header: {
            Text("Recordings")
        } footer: {
            Text("Recordings stay in Echo's local data folder on this Mac. Meetings with a saved recording can be re-transcribed and played back. Turning this off never deletes recordings already saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var deleteAllRecordingsLabel: String {
        guard savedRecordingsCount > 0 else { return "Delete All Saved Recordings…" }
        return "Delete All Saved Recordings (\(savedRecordingsCount) — \(byteText(savedRecordingsBytes)))…"
    }

    private func deleteAllRecordings() {
        Task {
            await controller.library.deleteAllPreservedAudio()
            await refreshRecordingTotals()
        }
    }

    private func refreshRecordingTotals() async {
        let totals = await controller.library.preservedAudioTotals()
        savedRecordingsCount = totals.meetings
        savedRecordingsBytes = totals.bytes
    }

    // MARK: - Summaries

    private var summariesSection: some View {
        Section {
            Toggle("Generate summaries automatically", isOn: Binding(
                get: { settings.autoGenerateSummaries },
                set: { settings.setAutoGenerateSummaries(enabled: $0) }
            ))
        } header: {
            Text("Summaries")
        } footer: {
            Text("When off, use Generate Summary on a meeting's AI Summary tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            storageRow("Meetings", bytes: controller.library.storageBreakdown?.meetingsBytes)
            storageRow(
                "Saved recordings",
                bytes: controller.library.storageBreakdown?.recordingsBytes
            )
            storageRow("Trash", bytes: controller.library.storageBreakdown?.trashBytes)
            VStack(alignment: .leading, spacing: 2) {
                storageRow("AI models", bytes: controller.library.storageBreakdown?.modelsBytes)
                Text("Models re-download automatically if removed.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                Button("Empty Trash…", role: .destructive) {
                    confirmEmptyTrash = true
                }
                .disabled(controller.library.trashedMetas.isEmpty)
                .confirmationDialog("Empty Trash?", isPresented: $confirmEmptyTrash) {
                    Button("Empty Trash", role: .destructive) { emptyTrash() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All \(controller.library.trashedMetas.count) meeting\(controller.library.trashedMetas.count == 1 ? "" : "s") in Trash (\(byteText(controller.library.storageBreakdown?.trashBytes ?? 0))) will be permanently deleted. This cannot be undone.")
                }

                Button("Reveal Data Folder in Finder") {
                    MeetingActions.revealInFinder(EchoPaths.appSupportDirectory)
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Everything Echo stores lives in one local folder: ~/Library/Application Support/Echo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func storageRow(_ title: String, bytes: Int64?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(bytes.map(byteText) ?? "Calculating…")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func emptyTrash() {
        Task {
            await controller.library.emptyTrash()
            controller.library.refreshStorageBreakdown()
            await refreshRecordingTotals()
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
