/*
 Hypnos - Atmos Object Spike (Settings → Developer)

 Picks a prepared scene from Documents/AtmosSpike or a Jellyfin item and
 opens the player that renders it (`AtmosSpikePlayerView`): its own window
 on visionOS, with tuning kept here beside it, or a tool sheet on iOS (via
 `IOSWindowRouter`) that holds the tuning itself. See `AtmosSpike.swift` for the scene format and how one
 is produced.
 */

import os
import SwiftUI

struct AtmosSpikeSection: View {
    @Bindable private var model = AtmosSpikeModel.shared
    @State private var selected: URL?
    @State private var searchTerm = ""
    @OpenWindowProxy private var openWindow
    @DismissWindowProxy private var dismissWindow

    var body: some View {
        Section("Atmos Object Spike") {
            if model.availableScenes.isEmpty {
                Text("Put a scene folder (audio.s16le + scene.json) in Documents/AtmosSpike.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Picker("Scene", selection: $selected) {
                    ForEach(model.availableScenes, id: \.self) { url in
                        Text(url.lastPathComponent).tag(Optional(url))
                    }
                }
                .pickerStyle(.menu)
            }

            jellyfinSource

            if let error = model.loadError {
                Text(error).font(.caption).foregroundColor(.red)
            }
            if let status = model.remoteStatus {
                Text(status).font(.caption.monospaced()).foregroundColor(.secondary)
            }

            Button {
                Task { await togglePlayer() }
            } label: {
                Label(model.isStageOpen ? "Close Player" : (model.isLoading ? "Loading…" : "Open Player"),
                      systemImage: model.isStageOpen ? "xmark.circle" : "speaker.wave.3")
            }
            .disabled(model.isLoading || (selected == nil && !model.isStageOpen))

            #if os(visionOS)
            if model.isStageOpen {
                AtmosSpikeTuning()
                AtmosSpikeTelemetry()
            }
            #endif

            Text("Plays Atmos objects decoded off-device (truehdd → DAMF) as RealityKit spatial sources placed in a virtual room around you, with the screen as its front wall. The map shows objects from above; colour follows height, size follows level. Local scenes come from Documents/AtmosSpike; Jellyfin items need the Atmos Objects server plugin.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .task {
            model.refreshScenes()
            if selected == nil { selected = model.loadedScene ?? model.availableScenes.first }
        }
    }

    /// Streams a library item from a Jellyfin server running the Atmos
    /// Objects plugin. Loading an item opens the space once it has buffered.
    private var jellyfinSource: some View {
        DisclosureGroup("Jellyfin") {
            TextField("Server (https://host/jellyfin)", text: $model.jellyfinServer)
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("API key", text: $model.jellyfinAPIKey)
            HStack {
                TextField("Search movies", text: $searchTerm)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await model.searchJellyfin(searchTerm) } }
                Button("Search") { Task { await model.searchJellyfin(searchTerm) } }
                    .disabled(searchTerm.isEmpty)
            }
            ForEach(model.searchResults) { item in
                Button {
                    Task { await openJellyfin(item) }
                } label: {
                    HStack {
                        Text(item.name)
                        if let year = item.productionYear {
                            Text(String(year)).foregroundColor(.secondary)
                        }
                        Spacer()
                        if model.loadedRemoteName == item.name {
                            Image(systemName: "speaker.wave.3.fill")
                        }
                    }
                }
                .disabled(model.isLoading)
            }
        }
    }

    private func openJellyfin(_ item: AtmosSpikeJellyfin.Item) async {
        closePlayer()
        await model.loadJellyfin(item)
        guard model.audio != nil, model.loadedRemoteName == item.name else { return }
        openPlayer()
    }

    private func togglePlayer() async {
        if model.isStageOpen {
            closePlayer()
            return
        }
        guard let selected else { return }
        if model.loadedScene != selected || model.audio == nil || model.loadedRemoteName != nil {
            await model.load(selected)
        }
        guard model.audio != nil else { return }
        openPlayer()
    }

    private func openPlayer() {
        openWindow(id: AtmosSpikePlayerView.windowID)
    }

    private func closePlayer() {
        dismissWindow(id: AtmosSpikePlayerView.windowID)
    }
}
