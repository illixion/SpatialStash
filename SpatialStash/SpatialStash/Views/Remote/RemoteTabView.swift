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
                                Image(systemName: config.mode.systemImage)
                                    .foregroundStyle(.secondary)
                                    .help(config.mode.label)
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
                                    appModel.saveRemoteConfig(config.duplicated(name: config.name + " (Copy)"))
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

                Section {
                    Picker("Mode", selection: $editingConfig.mode) {
                        ForEach(RemoteViewerMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Mode")
                } footer: {
                    Text(editingConfig.mode == .webPage
                         ? "Pins a web page in your space. The page keeps its state and window size; it only accepts input while the ornaments are visible."
                         : "Slideshow driven by a RoboFrame server (or the app's own gallery when the endpoint is blank).")
                }

                if editingConfig.mode == .webPage {
                    webPageSection
                } else {
                    slideshowSections
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
                        Text(editingConfig.mode == .webPage ? "Open Page" : "Launch Viewer")
                            .foregroundStyle(.blue)
                    }
                    .disabled(editingConfig.mode == .webPage && editingConfig.resolvedWebPageURL == nil)
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

    // MARK: - Web page mode

    @ViewBuilder
    private var webPageSection: some View {
        Section {
            TextField("Page URL", text: $editingConfig.webPageURL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)

            if !editingConfig.webPageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               editingConfig.resolvedWebPageURL == nil {
                Text("Not a usable URL.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let resolved = editingConfig.resolvedWebPageURL,
                      resolved.absoluteString != editingConfig.webPageURL.trimmingCharacters(in: .whitespacesAndNewlines) {
                Text("Opens \(resolved.absoluteString)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Toggle("Transparent Background", isOn: $editingConfig.webTransparentBackground)
            Text("Injects CSS so the page's own background paints through to your space. Pages that set a background on an inner element still paint it.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Auto-Refresh")
                    Spacer()
                    Text(RemoteViewerConfig.webAutoRefreshLabel(editingConfig.webAutoRefreshInterval))
                        .foregroundColor(.secondary)
                }
                Slider(
                    value: autoRefreshIndex,
                    in: 0...Double(RemoteViewerConfig.webAutoRefreshOptions.count - 1),
                    step: 1
                )
                Text("Reloads the page after this long with no interaction. Off by default.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Web Page")
        } footer: {
            Text("Tap the window to reveal the controls and unlock the page; hide them again (eye button, or let them auto-hide) to block input and stop visionOS from highlighting links as you look around.")
        }
    }

    /// Slider position for the auto-refresh interval. Snaps to the nearest
    /// preset so a value restored from an older build (or a backup) still lands
    /// on a real stop instead of reading as "Off".
    private var autoRefreshIndex: Binding<Double> {
        Binding(
            get: {
                let options = RemoteViewerConfig.webAutoRefreshOptions
                let current = editingConfig.webAutoRefreshInterval
                let nearest = options.enumerated().min { lhs, rhs in
                    abs(lhs.element - current) < abs(rhs.element - current)
                }
                return Double(nearest?.offset ?? 0)
            },
            set: { newValue in
                let options = RemoteViewerConfig.webAutoRefreshOptions
                let index = min(max(Int(newValue.rounded()), 0), options.count - 1)
                editingConfig.webAutoRefreshInterval = options[index]
            }
        )
    }

    // MARK: - Slideshow mode

    @ViewBuilder
    private var slideshowSections: some View {
        Section("API") {
            TextField("RoboFrame API Endpoint", text: $editingConfig.apiEndpoint)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            TextField("WebSocket Device ID", text: $editingConfig.wsDeviceId)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Text("Home Assistant uses this stable ID. The server keeps each window's slideshow session independent.")
                .font(.caption)
                .foregroundColor(.secondary)

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

            Picker("3D Mode", selection: $editingConfig.slideshow3DMode) {
                ForEach(Slideshow3DMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
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

        modTagPresetsSection
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
                            get: {
                                guard index < mtm.modTagLists.count else { return "" }
                                return mtm.modTagLists[index].joined(separator: " ")
                            },
                            set: { newValue in
                                guard index < bindable.wrappedValue.count else { return }
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
                    Text("Preset \(index + 1): \(index < mtm.modTagLists.count ? (mtm.modTagLists[index].first ?? "") : "")").tag(index)
                }
            }
            .pickerStyle(.menu)
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
