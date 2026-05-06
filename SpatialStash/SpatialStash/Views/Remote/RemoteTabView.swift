/*
 Spatial Stash - Remote Tab View

 Configuration interface for Remote API Viewer instances. Tag lists,
 blocked posts, and blocked tags are owned by the RoboFrame server and
 synced over the WebSocket; this view edits per-viewer display settings
 and the local "Default List" preference.
 */

import SwiftUI

struct RemoteTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var editingConfig = RemoteViewerConfig(name: "New Configuration")
    @State private var showSaveAlert = false
    @State private var saveName = ""
    @State private var selectedConfigId: UUID?
    @State private var newModTagPreset = ""

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            List {
                Section("Saved Configurations") {
                    if appModel.savedRemoteConfigs.isEmpty {
                        Text("No saved configurations")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(appModel.savedRemoteConfigs) { config in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(config.name)
                                    Text(config.savedDate, style: .date)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Load") {
                                    editingConfig = config
                                    selectedConfigId = config.id
                                }
                                .buttonStyle(.borderless)
                                Button("Copy") {
                                    var copy = RemoteViewerConfig(name: config.name + " (Copy)")
                                    copy.apiEndpoint = config.apiEndpoint
                                    copy.wsDeviceId = config.wsDeviceId
                                    copy.accessToken = config.accessToken
                                    copy.delay = config.delay
                                    copy.showClock = config.showClock
                                    copy.showSensors = config.showSensors
                                    copy.useAspectRatio = config.useAspectRatio
                                    copy.enableKenBurns = config.enableKenBurns
                                    copy.transparentBackground = config.transparentBackground
                                    copy.textSize = config.textSize
                                    copy.homeAssistantURL = config.homeAssistantURL
                                    appModel.saveRemoteConfig(copy)
                                }
                                .buttonStyle(.borderless)
                                Button("Launch") {
                                    launchViewer(config: config)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                appModel.deleteRemoteConfig(appModel.savedRemoteConfigs[index])
                            }
                        }
                    }
                }

                Section("API") {
                    TextField("RoboFrame API Endpoint", text: $editingConfig.apiEndpoint)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    TextField("WebSocket Device ID", text: $editingConfig.wsDeviceId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField("Access Token", text: $editingConfig.accessToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Display") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Image Interval")
                            Spacer()
                            Text(formatDelay(editingConfig.delay))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $editingConfig.delay, in: 3...120, step: 1)
                    }

                    Toggle("Show Clock", isOn: $editingConfig.showClock)
                    Toggle("Show Sensors", isOn: $editingConfig.showSensors)
                    Toggle("Fit to Window Aspect Ratio", isOn: $editingConfig.useAspectRatio)
                    Toggle("Ken Burns Effect", isOn: $editingConfig.enableKenBurns)
                    Toggle("Transparent Background", isOn: $editingConfig.transparentBackground)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Text Size")
                            Spacer()
                            Text(String(format: "%.0f%%", editingConfig.textSize * 100))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $editingConfig.textSize, in: 0.5...3.0, step: 0.1)
                    }
                }

                defaultListSection

                modTagPresetsSection

                Section("Home Assistant") {
                    TextField("Home Assistant URL", text: $editingConfig.homeAssistantURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section {
                    Button("Save Configuration") {
                        saveName = editingConfig.name
                        showSaveAlert = true
                    }

                    Button {
                        appModel.saveRemoteConfig(editingConfig)
                        launchViewer(config: editingConfig)
                    } label: {
                        Text("Launch Viewer")
                            .foregroundStyle(.blue)
                    }
                }
            }
            .navigationTitle("Remote Viewer")
            .onAppear {
                // Seed the "New Configuration" editor with the user's slideshow
                // defaults the first time it's shown. Once the user edits or
                // loads a saved config the defaults stop being relevant.
                if selectedConfigId == nil {
                    appModel.applySlideshowDefaults(to: &editingConfig)
                }
            }
            .alert("Save Configuration", isPresented: $showSaveAlert) {
                TextField("Name", text: $saveName)
                Button("Save") {
                    let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        editingConfig.name = name
                        appModel.saveRemoteConfig(editingConfig)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Mod tag presets (local)

    /// Mod tags don't persist on the server — they modify the active query
    /// for whichever channel this device is on. The catalog of presets
    /// lives entirely on this device; switching presets in the ornament
    /// pushes the active set to the server (and clears its query cache).
    @ViewBuilder
    private var modTagPresetsSection: some View {
        let mtm = appModel.modTagManager
        let bindable = Binding(
            get: { mtm.modTagLists },
            set: { mtm.modTagLists = $0 }
        )

        Section("Mod Tag Presets") {
            ForEach(mtm.modTagLists.indices, id: \.self) { index in
                HStack {
                    Text("Preset \(index + 1)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 70, alignment: .leading)
                    TextField(
                        "Tags (space-separated)",
                        text: Binding(
                            get: { mtm.modTagLists[index].joined(separator: " ") },
                            set: { newValue in
                                bindable.wrappedValue[index] = newValue
                                    .components(separatedBy: " ")
                                    .filter { !$0.isEmpty }
                            }
                        )
                    )
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                }
            }
            .onDelete { indexSet in
                bindable.wrappedValue.remove(atOffsets: indexSet)
            }

            HStack {
                TextField("Tags (space-separated)", text: $newModTagPreset)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Add Preset") {
                    let tags = newModTagPreset.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: " ")
                        .filter { !$0.isEmpty }
                    if !tags.isEmpty {
                        var lists = mtm.modTagLists
                        lists.append(tags)
                        mtm.modTagLists = lists
                        newModTagPreset = ""
                    }
                }
                .disabled(newModTagPreset.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Picker("Default Preset", selection: Binding(
                get: { mtm.defaultIndex ?? -1 },
                set: { mtm.defaultIndex = $0 == -1 ? nil : $0 }
            )) {
                Text("None").tag(-1)
                ForEach(mtm.modTagLists.indices, id: \.self) { index in
                    Text("Preset \(index + 1): \(mtm.modTagLists[index].first ?? "")").tag(index)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - Default List preference (local)

    /// The tag list catalog itself comes from the RoboFrame server and isn't
    /// editable here. The user's "Default List" preference is the only knob:
    /// pin to a specific list across reconnects, or let the server decide.
    private var defaultListSection: some View {
        let tlm = appModel.tagListManager

        return Section("Tag Lists") {
            if tlm.tagLists.isEmpty {
                Text("No tag lists from server yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Picker("Default List", selection: Binding(
                    get: { tlm.defaultIndex ?? -1 },
                    set: { tlm.defaultIndex = $0 == -1 ? nil : $0 }
                )) {
                    Text("Server Decides").tag(-1)
                    ForEach(tlm.tagLists.indices, id: \.self) { index in
                        Text("List \(index + 1): \(tlm.tagLists[index].first ?? "")").tag(index)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private func launchViewer(config: RemoteViewerConfig) {
        appModel.enqueueRemoteViewerOpen(configId: config.id)
    }

    private func formatDelay(_ seconds: TimeInterval) -> String {
        let intSeconds = Int(seconds)
        if intSeconds >= 60 {
            let minutes = intSeconds / 60
            let remainingSeconds = intSeconds % 60
            if remainingSeconds == 0 {
                return "\(minutes) min"
            }
            return "\(minutes) min \(remainingSeconds) sec"
        }
        return "\(intSeconds) seconds"
    }
}
