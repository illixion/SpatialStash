/*
 Console pop-out window.

 The console itself — the OSLogStore polling, the level/category/search
 filtering, the clipboard export — is RAVEConsole now, shared with the four
 other apps. What stays here is this app's way back to its main window.
 */

import RAVEConsole
import SwiftUI

struct ConsoleWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // No pop-out button: this *is* the pop-out.
        RAVEConsoleScreen()
            .padding(.bottom, 56)   // clear the ornament
            .ornament(attachmentAnchor: .scene(.bottomFront)) {
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

/// The console as a tab: the same screen, plus the button that pops it out.
struct ConsoleTabView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RAVEConsoleScreen { openWindow(id: "console") }
    }
}
