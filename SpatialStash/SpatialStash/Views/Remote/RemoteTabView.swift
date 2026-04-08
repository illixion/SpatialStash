/*
 Spatial Stash - Remote Tab View

 Configuration interface for Remote API Viewer instances.
 Allows editing settings, managing tag lists, saving/loading
 configurations, and launching viewer windows.
 */

import SwiftUI

struct RemoteTabView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var editingConfig = RemoteViewerConfig(name: "New Configuration")
    @State private var showSaveAlert = false
    @State private var saveName = ""
    @State private var showRenameAlert = false
    @State private var renamingConfig: RemoteViewerConfig?
    @State private var renameText = ""
    @State private var newTag = ""
    @State private var selectedConfigId: UUID?
    @State private var blockedTagsExpanded = false
    @State private var blockedPostsExpanded = false
    @State private var newBlockedTag = ""
    @State private var updateAllTagListsConfirming = false

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
                                    Text("\(config.tagLists.count) tag lists \u{00B7} \(config.savedDate, style: .date)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Load") {
                                    editingConfig = config
                                    selectedConfigId = config.id
                                }
                                .buttonStyle(.borderless)
                                Button("Rename") {
                                    renamingConfig = config
                                    renameText = config.name
                                    showRenameAlert = true
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

                    TextField("WebSocket Endpoint", text: $editingConfig.wsEndpoint)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    TextField("WebSocket Device ID", text: $editingConfig.wsDeviceId)
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

                Section("Tag Lists") {
                    ForEach(editingConfig.tagLists.indices, id: \.self) { index in
                        HStack {
                            Text("List \(index + 1)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 50, alignment: .leading)
                            TextField(
                                "Tags (space-separated)",
                                text: Binding(
                                    get: { editingConfig.tagLists[index].joined(separator: " ") },
                                    set: { newValue in
                                        editingConfig.tagLists[index] = newValue
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
                        editingConfig.tagLists.remove(atOffsets: indexSet)
                    }

                    HStack {
                        TextField("Tags (space-separated)", text: $newTag)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Add List") {
                            let tags = newTag.trimmingCharacters(in: .whitespaces)
                                .components(separatedBy: " ")
                                .filter { !$0.isEmpty }
                            if !tags.isEmpty {
                                editingConfig.tagLists.append(tags)
                                newTag = ""
                            }
                        }
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section {
                    DisclosureGroup(
                        "Blocked Tags (\(editingConfig.blockedTags.count))",
                        isExpanded: $blockedTagsExpanded
                    ) {
                        ForEach(editingConfig.blockedTags, id: \.self) { tag in
                            Text(tag)
                                .font(.body.monospaced())
                        }
                        .onDelete { indexSet in
                            editingConfig.blockedTags.remove(atOffsets: indexSet)
                        }

                        HStack {
                            TextField("Tag to block", text: $newBlockedTag)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button("Block") {
                                let tag = newBlockedTag.trimmingCharacters(in: .whitespaces)
                                if !tag.isEmpty {
                                    editingConfig.blockedTags.append(tag)
                                    newBlockedTag = ""
                                }
                            }
                        }
                    }

                    DisclosureGroup(
                        "Blocked Posts (\(editingConfig.blockedPosts.count))",
                        isExpanded: $blockedPostsExpanded
                    ) {
                        ForEach(editingConfig.blockedPosts, id: \.self) { postId in
                            Text("#\(postId)")
                                .font(.body.monospaced())
                        }
                        .onDelete { indexSet in
                            editingConfig.blockedPosts.remove(atOffsets: indexSet)
                        }
                    }
                }

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

                    Button(role: .destructive) {
                        if updateAllTagListsConfirming {
                            for index in appModel.savedRemoteConfigs.indices {
                                appModel.savedRemoteConfigs[index].tagLists = editingConfig.tagLists
                            }
                            updateAllTagListsConfirming = false
                        } else {
                            updateAllTagListsConfirming = true
                        }
                    } label: {
                        Text(updateAllTagListsConfirming ? "Are You Sure?" : "Update All Tag Lists")
                    }
                    .disabled(appModel.savedRemoteConfigs.isEmpty)

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
            .alert("Rename Configuration", isPresented: $showRenameAlert) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, let config = renamingConfig {
                        appModel.renameRemoteConfig(config, newName: name)
                    }
                    renamingConfig = nil
                }
                Button("Cancel", role: .cancel) {
                    renamingConfig = nil
                }
            }
        }
    }

    private func launchViewer(config: RemoteViewerConfig) {
        let windowValue = RemoteViewerWindowValue(configId: config.id)
        openWindow(id: "remote-viewer", value: windowValue)
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
