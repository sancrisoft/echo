//
//  PreservedRecordingBar.swift
//  Echo
//
//  The meeting detail's saved-recording surface (settings-page retention
//  §3.4): a quiet strip under the tab bar that exists exactly while the
//  meeting's folder holds preserved `audio-*` files — the indicator with the
//  on-disk size, an inline player (both channels on one timeline), Show in
//  Finder and Delete Recording. Re-transcribe joins it in its own slice.
//
//  Player timeline: both channels insert at `.zero` — the retained files
//  share the recording-relative origin by construction (gaps are written as
//  silence; `ParakeetPass` merges the channels the same way), so the
//  composition's duration is max(channels) and the voices align exactly as
//  the transcript's timestamps do.
//

import AVFoundation
import SwiftUI

// MARK: - Composition (pure, testable)

nonisolated enum PreservedPlayback {

    /// One composition with every channel's audio inserted at the timeline
    /// origin. A channel that fails to load is skipped (logged) — one broken
    /// file must not silence the other channel.
    static func composition(for files: [AudioChannel: URL]) async -> AVMutableComposition {
        let composition = AVMutableComposition()
        for url in files.values.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let asset = AVURLAsset(url: url)
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let duration = try await asset.load(.duration)
                let track = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                try track?.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: source,
                    at: .zero
                )
            } catch {
                ErrorTrace.record(
                    "Loading a preserved channel for playback failed",
                    error: error,
                    category: "PreservedPlayback",
                    metadata: ["file": url.lastPathComponent]
                )
            }
        }
        return composition
    }
}

// MARK: - Player model

/// Minimal transport over an `AVPlayer` of the two-channel composition:
/// play/pause, scrubber, elapsed/total. Torn down on detail disappear so a
/// closed detail never keeps audio running.
@MainActor
@Observable
final class PreservedRecordingPlayerModel {

    private(set) var player: AVPlayer?
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying = false

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func load(files: [AudioChannel: URL]) async {
        teardown()
        let composition = await PreservedPlayback.composition(for: files)
        let seconds = CMTimeGetSeconds(composition.duration)
        guard seconds.isFinite, seconds > 0 else { return }
        duration = seconds

        let player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = CMTimeGetSeconds(time)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.player?.seek(to: .zero)
                self?.currentTime = 0
            }
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to seconds: TimeInterval) {
        currentTime = seconds
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func teardown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}

// MARK: - Bar

/// Rendered by the detail for any saved meeting; probes the store and shows
/// nothing while the meeting has no preserved recording.
struct PreservedRecordingBar: View {
    let meetingID: UUID
    @Environment(RecordingController.self) private var controller

    @State private var files: [AudioChannel: URL] = [:]
    @State private var totalBytes: Int64 = 0
    @State private var model = PreservedRecordingPlayerModel()
    @State private var confirmDelete = false
    @State private var confirmRetranscribe = false

    var body: some View {
        Group {
            if files.isEmpty {
                // The probe's host, and the reason this branch exists at all.
                // A Group whose only branch is false renders no view, and a
                // `.task` with nothing to attach to never runs — so `files`
                // stayed empty forever and the bar was permanently invisible
                // on every meeting, saved recording or not. A zero-height
                // placeholder keeps the lifecycle alive; the detail's stack
                // has spacing 0, so it takes up nothing.
                Color.clear.frame(height: 0)
            } else {
                HStack(spacing: 12) {
                    Label(sizeText, systemImage: "waveform.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .help("This meeting's audio is saved in Echo's data folder")

                    playerControls

                    Menu {
                        Button {
                            confirmRetranscribe = true
                        } label: {
                            Label("Re-transcribe", systemImage: "arrow.clockwise")
                        }
                        Button {
                            MeetingActions.revealInFinder(controller.library.directory(for: meetingID))
                        } label: {
                            Label("Show Recording in Finder", systemImage: "folder")
                        }
                        Divider()
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete Recording…", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 24)
                .padding(.top, 10)
            }
        }
        .task(id: probeKey) { await probe() }
        .onDisappear { model.teardown() }
        .confirmationDialog("Delete this recording?", isPresented: $confirmDelete) {
            Button("Delete Recording", role: .destructive) { deleteRecording() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved audio (\(sizeText(totalBytes))) will be deleted. The transcript and summary stay. This cannot be undone.")
        }
        .confirmationDialog("Re-transcribe this meeting?", isPresented: $confirmRetranscribe) {
            Button("Re-transcribe") { retranscribe() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replaces this meeting's transcript and summary by re-running transcription on the saved recording. The recording itself is kept.")
        }
    }

    // MARK: Player

    @ViewBuilder
    private var playerControls: some View {
        if model.player != nil {
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.echoIndigo)
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "Pause" : "Play the saved recording")

            Slider(
                value: Binding(
                    get: { min(model.currentTime, model.duration) },
                    set: { model.seek(to: $0) }
                ),
                in: 0...max(model.duration, 0.01)
            )
            .controlSize(.mini)
            .frame(maxWidth: .infinity)

            Text("\(timeString(model.currentTime)) / \(timeString(model.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Spacer()
        }
    }

    // MARK: State

    /// Re-probes when a pass concludes for this meeting (a re-transcribe
    /// re-preserves the files) — the same lifecycle key the transcript face
    /// uses for its retained-audio probe.
    private struct ProbeKey: Equatable {
        let meetingID: UUID
        let runningMeetingID: UUID?
    }

    private var probeKey: ProbeKey {
        ProbeKey(meetingID: meetingID, runningMeetingID: controller.finalization.currentMeetingID)
    }

    private func probe() async {
        let found = await controller.library.preservedAudioFiles(for: meetingID)
        files = found
        totalBytes = found.values.reduce(Int64(0)) { total, url in
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return total + Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        if found.isEmpty {
            model.teardown()
        } else {
            await model.load(files: found)
        }
    }

    private func deleteRecording() {
        model.teardown()
        Task {
            await controller.library.deletePreservedAudio(for: meetingID)
            files = [:]
            totalBytes = 0
            // The sidebar footer's number just shrank — recompute it.
            await controller.library.refresh()
        }
    }

    private func retranscribe() {
        // Playback must not fight the pass for the files it's about to clone.
        model.teardown()
        Task { await controller.retranscribe(meetingID) }
    }

    // MARK: Formatting

    private var sizeText: String {
        "Recording saved · \(sizeText(totalBytes))"
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
