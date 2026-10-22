//
//  WindowChrome.swift
//  Workspace
//
//  The window itself, as opposed to what is inside it. The design draws one
//  surface from the top of the title bar to the bottom of the document, so the
//  title bar cannot stay the wallpaper-tinted material AppKit gives it by
//  default: over a near-black window it reads as a grey band across the top.
//  Making it transparent lets the window's own background — the design's —
//  show through it, traffic lights and title included.
//
//  The line under the title bar is the design's hairline, drawn by the content
//  at its top edge, so the system's separator is turned off rather than left
//  to draw a second one in a colour the palette does not have.
//

import AppKit
import SwiftUI

/// What a window has to be told to wear the design. A function over the
/// window, so it can be exercised on one without a scene or a host app.
enum WindowChrome {

    static func apply(to window: NSWindow, background: Color) {
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(background)
        window.titlebarSeparatorStyle = .none
    }
}

/// Dresses whichever window the view ends up in. Draws nothing.
struct WindowChromeReader: View {
    let background: Color

    var body: some View {
        WindowReader { window in
            guard let window else { return }
            WindowChrome.apply(to: window, background: background)
        }
    }
}

/// Hands the view's window to whoever needs to know which one it is. AppKit
/// answers this and SwiftUI does not; the view draws nothing.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        Reader(onWindow: onWindow)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    final class Reader: NSView {
        private let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("not from a nib")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}
