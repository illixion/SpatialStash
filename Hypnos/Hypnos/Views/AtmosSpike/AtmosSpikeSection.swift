/*
 Hypnos - Atmos Object Spike (Settings → Developer)

 Picks a prepared scene from Documents/AtmosSpike, opens the immersive space
 that renders it, and holds the transport and tuning controls — Settings
 stays usable next to a mixed space, so the knobs live here rather than in
 floating UI inside it. See `AtmosSpike.swift` for the scene format and how
 one is produced.
 */

#if os(visionOS)
import os
import SwiftUI

struct AtmosSpikeSection: View {
    @Bindable private var model = AtmosSpikeModel.shared
    @State private var selected: URL?
    @State private var searchTerm = ""
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

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
                Task { await toggleSpace() }
            } label: {
                Label(model.isSpaceOpen ? "Close Space" : (model.isLoading ? "Loading…" : "Open Space"),
                      systemImage: model.isSpaceOpen ? "xmark.circle" : "speaker.wave.3")
            }
            .disabled(model.isLoading || (selected == nil && !model.isSpaceOpen))

            if model.isSpaceOpen {
                transport
                tuning
                telemetry
            }

            Text("Plays Atmos objects decoded off-device (truehdd → DAMF) as RealityKit spatial sources placed in a virtual room around you. Spheres show object positions; size follows level. Local scenes come from Documents/AtmosSpike; Jellyfin items need the Atmos Objects server plugin.")
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
        if model.isSpaceOpen { await dismissImmersiveSpace() }
        await model.loadJellyfin(item)
        guard model.audio != nil, model.loadedRemoteName == item.name else { return }
        if case .opened = await openImmersiveSpace(id: "AtmosSpikeSpace") { return }
        AppLogger.atmosSpike.error("Immersive space did not open (another space may already be open)")
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Button {
                    model.isPlaying ? model.pause() : model.play()
                } label: {
                    Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { model.seek(to: model.positionSeconds - 10) } label: {
                    Label("−10s", systemImage: "gobackward.10")
                }
                Button { model.seek(to: model.positionSeconds + 10) } label: {
                    Label("+10s", systemImage: "goforward.10")
                }
                Button { model.seek(to: 0) } label: {
                    Label("Restart", systemImage: "backward.end")
                }
            }
            .buttonStyle(.bordered)
            Text(String(format: "%.1f / %.1f s", model.positionSeconds, model.durationSeconds))
                .font(.caption.monospaced())
        }
    }

    private var tuning: some View {
        Group {
            slider("Master", value: $model.masterGainDB, in: -24...12, unit: "dB")
            slider("LFE", value: $model.lfeGainDB, in: -24...10, unit: "dB")
            slider("Reverb", value: $model.reverbDB, in: -40...0, unit: "dB")
            slider("Room half-width", value: $model.roomHalfWidth, in: 0.5...5, unit: "m")
            slider("Room half-depth", value: $model.roomHalfDepth, in: 0.5...5, unit: "m")
            slider("Ceiling above ears", value: $model.roomHeight, in: 0...3, unit: "m")
            slider("Ear height", value: $model.earHeight, in: 0.8...2, unit: "m")
            Toggle("Flatten heights (A/B vs no height)", isOn: $model.flattenHeights)
            Toggle("Show object spheres", isOn: $model.showSpheres)
        }
    }

    private var telemetry: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "Render rate: %.0f Hz (scene %.0f Hz)", model.measuredRate, model.audio?.sampleRate ?? 0))
            Text("Clock: \(model.clockReport)")
            if !model.streamReport.isEmpty {
                Text("Stream: \(model.streamReport)")
            }
        }
        .font(.caption.monospaced())
        .foregroundColor(.secondary)
        .textSelection(.enabled)
    }

    private func slider(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(String(format: "%.1f", value.wrappedValue)) \(unit)").font(.caption)
            Slider(value: value, in: range)
        }
    }

    private func toggleSpace() async {
        if model.isSpaceOpen {
            await dismissImmersiveSpace()
            return
        }
        guard let selected else { return }
        if model.loadedScene != selected || model.audio == nil || model.loadedRemoteName != nil {
            await model.load(selected)
        }
        guard model.audio != nil else { return }
        switch await openImmersiveSpace(id: "AtmosSpikeSpace") {
        case .opened:
            break
        default:
            AppLogger.atmosSpike.error("Immersive space did not open (another space may already be open)")
        }
    }
}
#endif
