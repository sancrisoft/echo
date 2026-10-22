//
//  LaunchOriginTests.swift
//  AppTests
//
//  The events a launch was measured to receive (#208), built by hand: what
//  opens the window and what keeps a login quiet. Hosted only because the type
//  belongs to the app target.
//

import AppKit
import Testing

@testable import Echo

@Suite("Who asked for a launch")
struct LaunchOriginTests {

    private func openApplication(launchedAs: OSType? = nil) -> NSAppleEventDescriptor {
        let event = appleEvent(kCoreEventClass, kAEOpenApplication)
        if let launchedAs {
            // loginwindow's is a `typeType` descriptor, as measured.
            event.setParam(NSAppleEventDescriptor(typeCode: launchedAs), forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }

    private func appleEvent(_ eventClass: AEEventClass, _ id: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: eventClass,
            eventID: id,
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    @Test("a plain open-application event is the user's: Spotlight, Finder, Apps, open")
    func plainOpenIsTheUser() {
        #expect(LaunchOrigin.of(openApplication()) == .user)
    }

    @Test("an open-application event marked as a login item is the login's")
    func loginItemIsTheLogin() {
        #expect(LaunchOrigin.of(openApplication(launchedAs: OSType(keyAELaunchedAsLogInItem))) == .loginItem)
    }

    @Test("an open-application event marked any other way is not taken for the user's")
    func otherMarkIsUnrecognized() {
        #expect(LaunchOrigin.of(openApplication(launchedAs: OSType(keyAELaunchedAsServiceItem))) == .unrecognized)
    }

    @Test("no event, or another event, is not taken for the user's")
    func noOpenApplicationIsUnrecognized() {
        #expect(LaunchOrigin.of(nil) == .unrecognized)
        #expect(LaunchOrigin.of(appleEvent(kCoreEventClass, kAEReopenApplication)) == .unrecognized)
    }
}
