import SwiftUI

enum EchoV2Window {
    static let main = "main"
}

@main
struct EchoV2App: App {
    var body: some Scene {
        MenuBarExtra("Echo v2", systemImage: "waveform") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

        Window("Echo v2", id: EchoV2Window.main) {
            Color.clear
        }
        // An LSUIElement agent has no Dock icon to reopen it from, so the
        // window stays closed until the menu bar asks for it.
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 900, height: 600)
    }
}
