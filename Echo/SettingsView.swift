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
//  Storage land with their slices.
//

import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(RecordingController.self) private var controller
    @Environment(AppSettings.self) private var settings

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

    var body: some View {
        Form {
            generalSection
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
