import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Echo v2")
                .font(.headline)
            Button("Open Window") { openWindow(id: EchoV2Window.main) }
            Divider()
            // Without a Dock icon and without a menu bar of its own, this is
            // the only way out short of Force Quit.
            Button("Quit Echo v2") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 200, alignment: .leading)
    }
}
