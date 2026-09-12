//
//  WindowSnapshot.swift
//  Echo
//
//  The design-review and smoke-test hook behind `ECHO_SNAPSHOT_PATH` (DEBUG):
//  once the main window's content has had a moment to load, put the requested
//  scene on screen, render the window to a PNG at the given path, and quit.
//  Pixels cannot be captured from outside a window on this macOS, so the window
//  draws itself.
//

import AppKit
import EchoCore
import Island
import Meetings
import SwiftUI
import Workspace

#if DEBUG
    struct WindowSnapshot: ViewModifier {
        let composition: AppComposition

        func body(content: Content) -> some View {
            content.task {
                guard let path = composition.environment.snapshotPath else { return }
                // Let the library's launch refresh land before choosing a scene.
                try? await Task.sleep(for: .seconds(1.5))
                let scene = composition.environment.snapshotScene
                show(scene)
                // Let the scene load its document and lay out.
                try? await Task.sleep(for: .seconds(1.5))
                if scene == .island {
                    composition.island.snapshot(to: path)
                } else {
                    write(to: path)
                }
                NSApp.terminate(nil)
            }
        }

        private func show(_ scene: LaunchEnvironment.SnapshotScene) {
            let workspace = composition.workspace
            switch scene {
            case .library:
                workspace.section = .meetings
                workspace.selectedMeetingID = nil
            case .summary, .transcript:
                if let first = composition.library.metas.first {
                    workspace.open(first.id, tab: scene == .summary ? .summary : .transcript)
                }
            case .trash:
                workspace.section = .trash
            case .settings:
                workspace.section = .settings
            case .island:
                // Nothing to put on screen: the island is already up, and
                // which face it wears is not the window's to decide.
                break
            }
        }

        private func write(to path: URL) {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == EchoWindow.main }),
                let view = window.contentView
            else {
                ErrorTrace.record("Snapshot requested but the main window has no content view", category: "Snapshot")
                return
            }
            let bounds = view.bounds
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            view.cacheDisplay(in: bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            do {
                try data.write(to: path, options: .atomic)
            } catch {
                ErrorTrace.record("Writing the window snapshot failed", error: error, category: "Snapshot")
            }
        }
    }
#endif
