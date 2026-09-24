/*
 Hypnos - Film Player (Settings → Developer)

 Finds a film on a Jellyfin server running the Atmos Objects plugin and
 opens `FilmPlayerView`: its own window on visionOS, with tuning kept here
 beside it, or a tool sheet on iOS (via `IOSWindowRouter`) that holds the
 tuning itself.
 */

import RAVEFilm
import SwiftUI

struct FilmPlayerSection: View {
    @Bindable private var session = FilmSession.shared
    @State private var searchTerm = ""
    @OpenWindowProxy private var openWindow
    @DismissWindowProxy private var dismissWindow

    var body: some View {
        Section("Film Player") {
            TextField("Server (https://host/jellyfin)", text: $session.server)
                .textContentType(.URL)
                #if !os(macOS)
                .keyboardType(.URL)
                #endif
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            SecureField("API key", text: $session.apiKey)
            HStack {
                TextField("Search films", text: $searchTerm)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await session.search(searchTerm) } }
                Button("Search") { Task { await session.search(searchTerm) } }
                    .disabled(searchTerm.isEmpty)
            }
            ForEach(session.searchResults) { item in
                Button {
                    Task { await open(item) }
                } label: {
                    HStack {
                        Text(item.name)
                        if let year = item.productionYear {
                            Text(String(year)).foregroundColor(.secondary)
                        }
                        Spacer()
                        if session.loadedItem == item {
                            Image(systemName: "play.rectangle.fill")
                        }
                    }
                }
                .disabled(session.isLoading)
            }

            if session.isLoading {
                Text("Loading…").font(.caption.monospaced()).foregroundColor(.secondary)
            }
            if let error = session.error {
                Text(error).font(.caption).foregroundColor(.red)
            }

            if session.loadedItem != nil {
                Button {
                    session.isPlayerOpen ? closePlayer() : openPlayer()
                } label: {
                    Label(session.isPlayerOpen ? "Close Player" : "Open Player",
                          systemImage: session.isPlayerOpen ? "xmark.circle" : "play.rectangle")
                }
            }

            #if os(visionOS)
            if session.isPlayerOpen {
                FilmTuning()
                FilmTelemetry(player: session.player)
            }
            #endif

            Text("Plays the film's picture (HDR and Dolby Vision through the system decoder) with its Atmos objects as spatial sources in a virtual room around you, the screen as its front wall, on one clock. Needs the Atmos Objects plugin on the Jellyfin server; films without an Atmos track play picture only.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func open(_ item: FilmLibraryItem) async {
        closePlayer()
        guard await session.load(item) else { return }
        openPlayer()
    }

    private func openPlayer() {
        openWindow(id: FilmPlayerView.windowID)
    }

    private func closePlayer() {
        dismissWindow(id: FilmPlayerView.windowID)
    }
}
