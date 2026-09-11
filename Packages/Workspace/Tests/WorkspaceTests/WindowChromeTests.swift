//
//  WindowChromeTests.swift
//  WorkspaceTests
//
//  The title bar is the one surface a snapshot cannot check: the window
//  renders its content view, and the title bar is not in it. So the chrome is
//  checked on a real window instead — what it sets, and that the colour it
//  sets is the design's in both appearances.
//

import AppKit
import DesignSystem
import EchoCore
import EchoCoreTestSupport
import Meetings
import SwiftUI
import Testing

@testable import Workspace

@Suite("The window's chrome")
struct WindowChromeTests {

    private func window() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: EchoLayout.minimumWindow.width, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
    }

    @Test("the title bar stops being a material and takes the window's background")
    func titleBarTakesTheBackground() throws {
        let window = window()
        WindowChrome.apply(to: window, background: EchoColor.windowBackground)
        #expect(window.titlebarAppearsTransparent, "the title bar is still a wallpaper-tinted material")
        #expect(window.titlebarSeparatorStyle == .none, "the system would draw a second line under the title bar")
        let painted = try #require(window.backgroundColor.usingColorSpace(.sRGB))
        let expected = try #require(NSColor(EchoColor.windowBackground).usingColorSpace(.sRGB))
        #expect(abs(painted.redComponent - expected.redComponent) < 0.001)
        #expect(abs(painted.greenComponent - expected.greenComponent) < 0.001)
        #expect(abs(painted.blueComponent - expected.blueComponent) < 0.001)
        #expect(painted.alphaComponent == 1, "a translucent window background is a band waiting to happen")
    }

    @Test("the window the shell is hosted in is dressed, without anyone calling the chrome")
    func theShellDressesItsOwnWindow() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let dataRoot = DataRoot(url: temporary.url)
        let window = window()
        let hosting = NSHostingView(
            rootView: WorkspaceWindow(dataRoot: dataRoot)
                .environment(MeetingLibrary(dataRoot: dataRoot))
                .environment(WorkspaceModel())
                .environment(AppSettings(dataRoot: dataRoot)))
        window.contentView = hosting
        // The representable's view reaches the window during layout; no sleep,
        // just the layout the window would do anyway.
        window.layoutIfNeeded()
        #expect(window.titlebarAppearsTransparent, "the shell did not dress the window it was put in")
        #expect(window.titlebarSeparatorStyle == .none)
    }

    @Test("the background it paints follows the appearance, at the design's values")
    func theBackgroundIsTheDesignsInBothAppearances() throws {
        let window = window()
        WindowChrome.apply(to: window, background: EchoColor.windowBackground)
        for (name, hex) in [(NSAppearance.Name.aqua, 0xFF_FFFF), (.darkAqua, 0x0D_0E11)] {
            let appearance = try #require(NSAppearance(named: name))
            var drawn: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                drawn = window.backgroundColor.usingColorSpace(.sRGB)
            }
            let resolved = try #require(drawn)
            let expected = NSColor(hex: UInt32(hex))
            #expect(abs(resolved.redComponent - expected.redComponent) < 0.001, "red in \(name.rawValue)")
            #expect(abs(resolved.greenComponent - expected.greenComponent) < 0.001, "green in \(name.rawValue)")
            #expect(abs(resolved.blueComponent - expected.blueComponent) < 0.001, "blue in \(name.rawValue)")
        }
    }
}
