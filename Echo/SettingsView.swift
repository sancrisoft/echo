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

import SwiftUI

struct SettingsView: View {
    @Environment(RecordingController.self) private var controller
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            callDetectionSection
            recordingsSection
            summariesSection
        }
        .formStyle(.grouped)
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
        } header: {
            Text("Call Detection")
        } footer: {
            Text("Echo watches for catalogued meeting apps using the microphone and offers to record.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Recordings

    private var recordingsSection: some View {
        Section {
            Toggle("Keep audio recordings after transcription", isOn: Binding(
                get: { settings.keepRecordingsAfterTranscription },
                set: { settings.setKeepRecordings(enabled: $0) }
            ))
        } header: {
            Text("Recordings")
        } footer: {
            Text("Recordings stay in Echo's local data folder on this Mac. Meetings with a saved recording can be re-transcribed and played back. Turning this off never deletes recordings already saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
}
