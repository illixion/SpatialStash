/*
 Hypnos - film player session (Settings → Developer → Film Player)

 App glue around RAVEFilm's `FilmPlayer`: the Jellyfin server and API
 key, library search, which item is loaded, and whether the player is
 showing. The player itself (picture, Atmos object audio, one clock) lives
 in RAVESDK's `RAVEFilm` target. The server needs the Atmos
 Objects plugin (`JellyfinPlugin/`), which serves both the video segments
 and the object audio.
 */

import RAVEFilm
import Foundation
import Observation
import os

@MainActor
@Observable
final class FilmSession {
    static let shared = FilmSession()

    let player = FilmPlayer()

    var server: String = UserDefaults.standard.string(forKey: "filmPlayer.jellyfinServer")
        ?? UserDefaults.standard.string(forKey: "atmosSpike.jellyfinServer") ?? "" {
        didSet { UserDefaults.standard.set(server, forKey: "filmPlayer.jellyfinServer") }
    }
    var apiKey: String = KeychainStore.string(for: .jellyfinAPIKey) ?? "" {
        didSet { KeychainStore.set(apiKey, for: .jellyfinAPIKey) }
    }

    private(set) var searchResults: [FilmLibraryItem] = []
    private(set) var loadedItem: FilmLibraryItem?
    private(set) var isLoading = false
    private(set) var error: String?
    /// Whether the player window (or the iOS sheet) is showing.
    var isPlayerOpen = false

    /// visionOS: how far in front of the player window the listener is
    /// assumed to sit. A window can't see the head, so this is a guess.
    var listenerDistance: Float = 1.5
    var showMap = false

    private init() {}

    private var serverURL: URL? {
        let trimmed = server.trimmingCharacters(in: .whitespaces)
        guard !apiKey.isEmpty,
              let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed),
              url.scheme != nil else { return nil }
        return url
    }

    func search(_ term: String) async {
        guard let serverURL else {
            error = "Set the Jellyfin server URL and API key first."
            return
        }
        do {
            searchResults = try await FilmServerClient.search(baseURL: serverURL, token: apiKey, term: term)
            error = searchResults.isEmpty ? "No items match “\(term)”." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Loads `item` into the player. True when its picture is ready to play.
    func load(_ item: FilmLibraryItem) async -> Bool {
        guard let serverURL, !isLoading else { return false }
        isLoading = true
        error = nil
        defer { isLoading = false }
        await player.load(FilmServerClient(baseURL: serverURL, token: apiKey, itemID: item.id))
        guard player.video.index != nil else {
            error = player.video.status
            return false
        }
        loadedItem = item
        AppLogger.filmPlayer.info("Loaded \(item.name, privacy: .public): \(self.player.video.formatSummary, privacy: .public); audio \(self.player.audioStatus, privacy: .public)")
        return true
    }
}
