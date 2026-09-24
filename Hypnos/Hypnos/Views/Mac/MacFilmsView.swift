/*
 Hypnos - macOS Films section

 Mirrors `TVFilmsTabView`: Jellyfin search and playback over the same
 `FilmSession` every platform uses. Unlike tvOS/iOS/visionOS this doesn't
 present the player as a cover or sheet — macOS gets a real, separate "Film
 Player" window (`HypnosApp`'s `macOSScenes`), opened once a film has loaded.
 */

#if os(macOS)

import RAVEFilm
import SwiftUI

struct MacFilmsView: View {
    @Bindable private var session = FilmSession.shared
    @State private var searchTerm = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Jellyfin Server") {
                TextField("Server (https://host/jellyfin)", text: $session.server)
                    .autocorrectionDisabled()
                SecureField("API key", text: $session.apiKey)
            }

            Section("Search") {
                HStack {
                    TextField("Search films", text: $searchTerm)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await session.search(searchTerm) } }
                    Button("Search") { Task { await session.search(searchTerm) } }
                        .disabled(searchTerm.isEmpty)
                }

                if session.isLoading {
                    ProgressView("Loading…")
                }
                if let error = session.error {
                    Text(error).foregroundStyle(.red)
                }

                ForEach(session.searchResults) { item in
                    Button {
                        Task { await open(item) }
                    } label: {
                        HStack {
                            Text(item.name)
                            if let year = item.productionYear {
                                Text(String(year)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if session.loadedItem == item {
                                Image(systemName: "play.rectangle.fill")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Text("Plays the film's picture (HDR and Dolby Vision through the system decoder) plus its Atmos object audio — without AirPods head tracking, which is iOS-only, so the sound stage stays fixed relative to the picture instead of turning with a listener's head. Needs the Atmos Objects plugin on the Jellyfin server. See Hypnos/CLAUDE.md \"macOS\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func open(_ item: FilmLibraryItem) async {
        guard await session.load(item) else { return }
        session.isPlayerOpen = true
        openWindow(id: FilmPlayerView.windowID)
    }
}

#endif
