//
//  LaunchOrigin.swift
//  Echo
//
//  Who asked for this launch. A cold launch the user asked for — Spotlight,
//  Finder, the Apps launcher, `open` — and one loginwindow made because Echo
//  is a login item look the same to the process: launchd is the parent of
//  both, the environment is the same, and `NSApplicationLaunchIsDefaultLaunchKey`
//  is true for both. What differs is the open-application event every launch
//  receives: loginwindow sends it with `keyAELaunchedAsLogInItem` as its
//  property data, and no other path tested did.
//
//  Measured on 2026-10-21 (#208, macOS 27) with a probe that has Echo's
//  lifecycle — a SwiftUI `App`, the delegate adaptor, `LSUIElement`, a
//  suppressed `Window` — registered with `SMAppService.mainApp`: a bare
//  `oapp` from Spotlight, Finder, the Apps launcher (followed at once by a
//  reopen), `open` and the binary run by hand; an `oapp` marked as a login
//  item, sent by loginwindow, at login, including for a login item still
//  running at logout, which was launched once. An agent app running at
//  logout that is not a login item was not relaunched at all.
//

import AppKit

enum LaunchOrigin: Equatable {
    /// Someone opened Echo: Spotlight, Finder, the Apps launcher, the Dock,
    /// `open`, the updater's reopen, the binary run by hand.
    case user
    /// loginwindow opened Echo at login because it is a login item.
    case loginItem
    /// No open-application event, or one this does not recognise. None was
    /// seen; if one ever is, it is treated as a launch nobody asked for,
    /// because a window in front of someone who did not ask for it is the
    /// costlier mistake.
    case unrecognized

    /// Reads the launch's open-application event. That event is AppKit's
    /// current Apple event only inside `applicationDidFinishLaunching` — not
    /// in `App.init`, not in `applicationWillFinishLaunching`, and gone one
    /// run-loop tick later (measured with the same probe) — so the delegate
    /// reads it there.
    static func of(_ event: NSAppleEventDescriptor?) -> LaunchOrigin {
        guard
            let event,
            event.eventClass == kCoreEventClass,
            event.eventID == kAEOpenApplication
        else { return .unrecognized }
        guard let launchedAs = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)) else {
            return .user
        }
        return launchedAs.typeCodeValue == OSType(keyAELaunchedAsLogInItem) ? .loginItem : .unrecognized
    }
}
