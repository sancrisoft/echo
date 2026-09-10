//
//  SettingsScreen.swift
//  Workspace
//
//  The settings that exist for the library: launch at login, recordings,
//  summaries, storage. Sections for call detection, models and updates arrive
//  with the packages that own them. Launch at login reads `SMAppService`, the
//  OS's own answer, and is never mirrored into `settings.json`: the user can
//  change login items in System Settings behind our back.
//

import DesignSystem
import EchoCore
import Meetings
import ServiceManagement
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingLibrary.self) private var library

    let dataRoot: DataRoot

    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?
    @State private var confirmDeleteRecordings = false
    @State private var confirmEmptyTrash = false

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
