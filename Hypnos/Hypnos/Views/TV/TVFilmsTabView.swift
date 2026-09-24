/*
 Hypnos - tvOS Films tab

 Jellyfin film search and playback, over the same `FilmSession` the
 visionOS window and iOS tool sheet use (see `Services/FilmSession.swift`
 and `Views/FilmPlayer/FilmPlayerView.swift`'s `#elseif os(tvOS)` branch).
 This tab is the search/browse UI; the actual player is `FilmPlayerView`,
 unchanged, presented fullscreen.
 */

#if os(tvOS)

import RAVEFilm
import SwiftUI

struct TVFilmsTabView: View {
    @Bindable private var session = FilmSession.shared
    @State private var searchTerm = ""

    var body: some View {
        NavigationStack {
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
                    }
                }

                Section {
                    Text("Plays the film's picture (HDR and Dolby Vision through the system decoder) with static HDR metadata and display criteria, so the TV switches mode to match. Needs the Atmos Objects plugin on the Jellyfin server for full films; the Atmos object audio itself isn't played on Apple TV (no headphone or AVP head tracking to place it against) — films play their picture only. See Hypnos/CLAUDE.md \"tvOS\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Films")
        }
        .fullScreenCover(isPresented: $session.isPlayerOpen) {
            FilmPlayerView()
        }
    }

    private func open(_ item: FilmLibraryItem) async {
        guard await session.load(item) else { return }
        session.isPlayerOpen = true
    }
}

#endif
