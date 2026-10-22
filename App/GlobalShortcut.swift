//
//  GlobalShortcut.swift
//  Echo
//
//  Control + Option + E, from anywhere: at rest it starts the same gated
//  recording every other surface starts, and while recording it stops (#119,
//  product owner 2026-10-02). Fixed for now; four-key combinations were turned
//  down because they cannot be pressed with one hand.
//
//  Carbon's `RegisterEventHotKey`, because it asks for no permission: an
//  `NSEvent` global monitor needs Accessibility, and a recorder whose shortcut
//  only works after a trip to Privacy & Security is a shortcut most people
//  never get. The key is claimed for the whole system while Echo runs, which
//  is the point. A registration that fails is traced rather than shown, since
//  nothing on screen asked for it, and every command stays in the menu.
//
//  One definition of the combination, for the two places it appears: the
//  registration, and the key equivalent the menu shows beside Record and Stop.
//

import AppKit
import Carbon.HIToolbox
import EchoCore
import Recording
import os

@MainActor
final class GlobalShortcut {

    /// How the menu writes it, beside the command it runs.
    static let keyEquivalent = "e"
    static let modifiers: NSEvent.ModifierFlags = [.control, .option]

    /// The same in words a view can draw, the modifiers in the order menus
    /// put them: what the keyboard shortcuts panel lists.
    static var display: String {
        let glyphs: [(NSEvent.ModifierFlags, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
        ]
        return glyphs.filter { modifiers.contains($0.0) }.map(\.1).joined() + keyEquivalent.uppercased()
    }

    /// The same, as Carbon names it: the physical key (so a keyboard layout
    /// that moves the letter moves nothing), and its modifier bits.
    private static let keyCode = UInt32(kVK_ANSI_E)
    private static let carbonModifiers = UInt32(controlKey | optionKey)

    /// "Echo", as the four-character code Carbon tells hot keys apart by.
    private static let signature: OSType = 0x4563_686F

    /// What one press does, decided from the session's phase alone.
    enum Press: Equatable {
        case start
        case stop
        /// A teardown is under way; a second press must not start a second.
        case nothing

        /// Recording stops. Anything that is not capture starts — the work
        /// after a stop included, which never blocks a new recording: the
        /// session preempts its own pass for one.
        static func of(_ phase: RecordingPhase) -> Press {
            switch phase {
            case .recording: .stop
            case .stopping: .nothing
            case .idle, .finalizing, .summarizing: .start
            }
        }
    }

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "GlobalShortcut")

    private let pressed: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// - Parameter pressed: what a press does. Called on the main thread,
    ///   where Carbon dispatches application events.
    init(pressed: @escaping () -> Void) {
        self.pressed = pressed
    }

    /// Claims the combination. A launch side effect — the composition root's,
    /// and inert under a test host like every other one (ADR-004).
    func register() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                // Carbon calls back on the main thread, from the run loop
                // AppKit drives; the context is the shortcut that registered.
                guard let context else { return OSStatus(eventNotHandledErr) }
                let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    GlobalShortcut.log.info("Global shortcut pressed")
                    shortcut.pressed()
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard installed == noErr else {
            ErrorTrace.record(
                "The global shortcut's handler could not be installed", category: "GlobalShortcut",
                metadata: ["status": "\(installed)"])
            return
        }
        let registered = RegisterEventHotKey(
            Self.keyCode,
            Self.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registered == noErr else {
            // Echo works without it: every command is still in the menu.
            ErrorTrace.record(
                "The global shortcut could not be registered", category: "GlobalShortcut",
                metadata: ["status": "\(registered)"])
            hotKey = nil
            return
        }
        // How a person checking the shortcut on a Mac knows it was claimed:
        // keystrokes cannot be synthesised from outside the app (TCC).
        Self.log.info("Global shortcut registered")
    }
}
