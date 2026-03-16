/*
 Spatial Stash - Console Window View

 Standalone pop-out window for the debug console.
 Wraps DebugConsoleView with an ornament for navigating back to the main window.
 */

import SwiftUI

struct ConsoleWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        DebugConsoleView(isPopOut: true)
            .padding(.bottom, 56) // Add padding to prevent overlap with ornament
            .ornament(
                attachmentAnchor: .scene(.bottomFront)
            ) {
                HStack(spacing: 16) {
                    Button {
                        appModel.showMainWindow(openWindow: openWindow)
                    } label: {
                        Label("Gallery", systemImage: "photo.on.rectangle")
                    }
                }
                .padding(12)
                .glassBackgroundEffect()
            }
    }
}
