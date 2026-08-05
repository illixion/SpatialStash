/*
 Spatial Stash - Settings Tab View

 Settings view with server configuration and source selection.
 */

import os
import SwiftUI
import UniformTypeIdentifiers

struct SettingsTabView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MainWindowModel.self) private var windowModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?
    @Environment(\.openWindow) private var openWindow
    @State private var showSaveGroupAlert = false
    @State private var newGroupName = ""
    @State private var showRenameGroupAlert = false
    @State private var renamingGroup: SavedWindowGroup?
    @State private var renameGroupName = ""
    @State private var restoreSheetGroup: SavedWindowGroup?
    /// Depth models discovered in Documents/bundle, for the Fake-3D pickers.
    @State private var depthModels = DepthModelManager.shared
    @State private var showDepthModelManager = false
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var exportDocument: SettingsBackupDocument?
    @State private var isExporting = false
    @State private var showImportConfirmation = false
    @State private var pendingImportData: Data?
    @State private var showImportSuccess = false
    @State private var showImportError = false
    @State private var importErrorMessage = ""
    @State private var showEnhancementsClearConfirmation = false

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            List {
                Section("Display") {
                    Toggle("Reduce Motion", isOn: $appModel.reduceMotion)
                    if appModel.systemReduceMotion && !appModel.reduceMotion {
                        Text("Currently enforced by system Accessibility setting.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !appModel.effectiveReduceMotion {
                        Picker("Thumbnail Style", selection: $appModel.thumbnailStyle) {
                            ForEach(ThumbnailStyle.allCases) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Toggle("Rounded Corners", isOn: $appModel.roundedCorners)

                    Toggle("Always Open In New Window", isOn: $appModel.openMediaInNewWindows)

                    Toggle("Remember Image Enhancements", isOn: Binding(
                        get: { appModel.rememberImageEnhancements },
                        set: { newValue in
                            if newValue {
                                appModel.rememberImageEnhancements = true
                            } else {
                                showEnhancementsClearConfirmation = true
                            }
                        }
                    ))

                    if appModel.rememberImageEnhancements {
                        Toggle("Remember Last 3D State", isOn: $appModel.autoRestoreSpatial3D)
                    }

                    Picker("Default Viewing Mode", selection: $appModel.defaultImageViewingMode) {
                        ForEach(DefaultImageViewingMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("2D Image Resolution Limit", selection: $appModel.maxImageResolution) {
                        ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Spatial 3D Resolution Limit", selection: $appModel.spatial3DMaxResolution) {
                        ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("Fully Immersive 3D Mode", isOn: $appModel.fullyImmersive3DMode)

                    Toggle("Mute Videos on Open", isOn: $appModel.videoAutoplayMuted)
                    Text("Videos always start playing automatically; turn this off to open them with sound. Applies to video windows and the gallery long-press preview.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Fake-3D depth models, per pipeline: real-time inference
                    // gates every frame (keep this fast), while pre-process
                    // conversion can afford a slower, higher-quality model.
                    // Models are added/removed in Developer → Depth Model Manager.
                    depthModelPicker(
                        "Real-Time 3D Depth Model",
                        selection: $appModel.realtimeDepthModelName
                    )
                    depthModelPicker(
                        "Pre-Process 3D Depth Model",
                        selection: $appModel.preprocessDepthModelName
                    )
                    Toggle("Real-Time 3D for All Videos", isOn: $appModel.defaultRealtimePseudo3D)
                    Text("Convert to 3D uses these models: Real-Time for instant playback (fast model recommended), Pre-Process for background conversion (a larger model can be used). Manage installed models under Developer. With Real-Time 3D for All Videos on, compatible videos open already converted — using this video's pre-processed conversion when available, otherwise real-time.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Diorama Layer Distance", selection: $appModel.dioramaDistance) {
                        ForEach(AppModel.dioramaDistanceOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Auto-hide Controls After", selection: $appModel.autoHideDelay) {
                        ForEach(AppModel.autoHideDelayOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Delay")
                            Spacer()
                            Text(formatSlideshowDelay(appModel.slideshowDelay))
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: $appModel.slideshowDelay,
                            in: 3...120,
                            step: 1
                        )
                    }

                    Toggle("Show Clock", isOn: $appModel.slideshowShowClock)
                    Toggle("Show Sensors", isOn: $appModel.slideshowShowSensors)
                    Toggle("Fit to Window Aspect Ratio", isOn: $appModel.slideshowUseAspectRatio)
                    Toggle("Ken Burns Effect", isOn: $appModel.slideshowEnableKenBurns)
                    Toggle("Dynamic Brightness", isOn: $appModel.slideshowEnableDynamicBrightness)
                    Toggle("Diorama Layers", isOn: $appModel.slideshowEnableDiorama)
                    Toggle("Transparent Background", isOn: $appModel.slideshowTransparentBackground)

                    Picker("Max Image Resolution (2D)", selection: $appModel.slideshowMaxImageResolution2D) {
                        ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Max Image Resolution (3D)", selection: $appModel.slideshowMaxImageResolution3D) {
                        ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Text Size")
                            Spacer()
                            Text(String(format: "%.0f%%", appModel.slideshowTextSize * 100))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $appModel.slideshowTextSize, in: 0.5...3.0, step: 0.1)
                    }
                } header: {
                    Text("Slideshow Defaults")
                } footer: {
                    Text("Used when starting a slideshow from any source. Saved Remote API profiles override these per-profile.")
                }

                windowGroupsSection

                Section("Stash Server") {
                    TextField("Server URL", text: $appModel.stashServerURL)
                        .textFieldStyle(.plain)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onSubmit {
                            appModel.updateAPIClient()
                        }

                    SecureField("API Key (optional)", text: $appModel.stashAPIKey)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit {
                            appModel.updateAPIClient()
                        }

                    Button("Apply & Test Connection") {
                        appModel.updateAPIClient()
                        Task {
                            await testConnection()
                        }
                    }

                    Toggle("Server-Side Transcoding", isOn: $appModel.enableStashTranscoding)
                    Text("Keep the Stash server's HLS transcode in reserve. Scenes always play their original file first (WebM decodes on-device in WebKit); the transcode is used only if that file can't be played, or when a feature needs AVFoundation — Convert to 3D, immersive 3D, depth pre-processing. Turn off to never transcode, which leaves those unavailable for WebM. Applies to newly loaded scenes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Gallery Statistics") {
                    HStack {
                        Text("Images Loaded")
                        Spacer()
                        Text("\(appModel.galleryImages.count)")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Videos Loaded")
                        Spacer()
                        Text("\(appModel.galleryVideos.count)")
                            .foregroundColor(.secondary)
                    }
                }

                CacheSettingsSection()

                Section("Backup") {
                    Button {
                        isExporting = true
                        Task {
                            let backup = await appModel.exportSettingsBackup()
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            encoder.dateEncodingStrategy = .iso8601
                            if let data = try? encoder.encode(backup) {
                                exportDocument = SettingsBackupDocument(data: data)
                                showExporter = true
                            }
                            isExporting = false
                        }
                    } label: {
                        if isExporting {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Preparing...")
                            }
                        } else {
                            Label("Export Settings", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isExporting)

                    Button {
                        showImporter = true
                    } label: {
                        Label("Import Settings", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        importFromDocuments()
                    } label: {
                        Label("Import from Documents Folder", systemImage: "folder")
                    }
                }

                Section("Developer") {
                    Toggle("Enable RoboFrame Viewer", isOn: Binding(
                        get: { appModel.enableRemoteViewer },
                        set: { newValue in
                            appModel.enableRemoteViewer = newValue
                            if !newValue && windowModel.selectedTab == .remote {
                                windowModel.selectedTab = .settings
                            }
                        }
                    ))
                    Text("Enable viewer for RoboFrame photo slideshow engine, see README.md for info on backend setup.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Show Debug Console", isOn: Binding(
                        get: { appModel.showDebugConsole },
                        set: { newValue in
                            appModel.showDebugConsole = newValue
                            if !newValue && windowModel.selectedTab == .console {
                                windowModel.selectedTab = .settings
                            }
                        }
                    ))
                    Text("Adds a Console tab showing app log messages in real time.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Web yt-dlp Support", isOn: $appModel.webYTDLPEnabled)
                    if appModel.webYTDLPEnabled {
                        TextField("Endpoint URL", text: $appModel.webYTDLPEndpoint)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        SecureField("Token", text: $appModel.webYTDLPToken)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Picker("Codec", selection: $appModel.webYTDLPPreset) {
                            ForEach(AppModel.webYTDLPPresetOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        Picker("Max Resolution", selection: $appModel.webYTDLPHeight) {
                            ForEach(AppModel.webYTDLPHeightOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        Link("web-yt-dlp on GitHub", destination: URL(string: "https://github.com/illixion/web-yt-dlp")!)
                            .font(.caption)
                        Link("“Open in Spatial Viewer” Shortcut", destination: URL(string: "https://www.icloud.com/shortcuts/c313953ed4c245f988ca746808109b8d")!)
                            .font(.caption)
                    }
                    Text("Play web videos (e.g. YouTube) in 3D by routing page links through a self-hosted web-yt-dlp proxy. Hand a link to the app with the \"Open in Spatial Viewer\" Shortcut or a bookmarklet opening spatialstash://play?url=… — see the repo README. Direct stream links (MP4/HLS) play without this. The proxy re-encodes to the chosen codec (HEVC recommended on Apple platforms) at up to the chosen height.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Respect System Memory Alerts", isOn: $appModel.respectMemoryAlerts)
                    Text("When disabled, the app will not unload images or downscale windows in response to system memory pressure.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Lossy Texture Compression", isOn: $appModel.useLossyTextureCompression)
                    Text("Reduces GPU memory per image by ~2-4x using hardware lossy compression. Slight quality reduction. New images use the updated setting; existing windows are unaffected until reloaded.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Fake-3D depth models are managed (added/downloaded/deleted)
                    // in a dedicated modal; which model each pipeline USES is
                    // picked in the Display section's two dropdowns.
                    Button {
                        showDepthModelManager = true
                    } label: {
                        Label("Depth Model Manager", systemImage: "shippingbox")
                    }
                    if let downloading = DepthModelManager.variants.first(where: { depthModels.isDownloading($0) }) {
                        HStack(spacing: 12) {
                            ProgressView(value: depthModels.progress[downloading.name] ?? 0)
                            Text("Downloading \(downloading.displayName)…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Text("Pseudo 3D video requires a monocular depth model (~19–50 MB, downloaded from Apple's Hugging Face repo). Videos already pre-processed keep playing in 3D even without a model.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Pre-processed fake-3D depth caches (Convert to 3D → Pre-Process).
                    DepthCacheSettingsView()

                    Button {
                        openWindow(id: "gpu-memory")
                    } label: {
                        Label("Open GPU Memory Monitor", systemImage: "memorychip")
                    }

                    Button(appModel.allWindowsHidden ? "Unhide All Windows" : "Hide All Windows") {
                        appModel.allWindowsHidden.toggle()
                    }
                    .disabled(!hasSecondaryWindows && !appModel.allWindowsHidden)

                    Button("Close All Windows", role: .destructive) {
                        closeAllSecondaryWindows()
                        appModel.allWindowsHidden = false
                    }
                    .disabled(!hasSecondaryWindows)
                }

                #if SPATIALSTASH_PRIVATE_API
                PrivateSpatial3DTuningSection()
                #endif

                Section("About") {
                    HStack {
                        Text("App Name")
                        Spacer()
                        Text("Spatial Stash")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersionString)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .task {
                depthModels.importInboxIfNeeded()
            }
            .sheet(isPresented: $showDepthModelManager) {
                DepthModelManagerSheet()
                    .environment(appModel)
            }
            .alert("Save Window Group", isPresented: $showSaveGroupAlert) {
                TextField("Group Name", text: $newGroupName)
                Button("Save") {
                    let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        appModel.saveCurrentWindowGroup(name: name)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a name for this arrangement of \(openWindowCount) open \(openWindowCount == 1 ? "window" : "windows"). Each window's position is remembered by visionOS; the group remembers what it showed and how big it was.")
            }
            .alert("Rename Window Group", isPresented: $showRenameGroupAlert) {
                TextField("Group Name", text: $renameGroupName)
                Button("Rename") {
                    let name = renameGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, let group = renamingGroup {
                        appModel.renameSavedWindowGroup(group, newName: name)
                    }
                    renamingGroup = nil
                }
                Button("Cancel", role: .cancel) {
                    renamingGroup = nil
                }
            } message: {
                Text("Enter a new name for this window group.")
            }
            .sheet(item: $restoreSheetGroup) { group in
                WindowGroupRestoreSheet(group: group)
                    .environment(appModel)
            }
            .fileExporter(
                isPresented: $showExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "SpatialStash-Backup-\(backupDateString()).json"
            ) { _ in
                exportDocument = nil
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json]
            ) { result in
                switch result {
                case .success(let url):
                    // startAccessing legitimately returns false for URLs that
                    // aren't security-scoped (e.g. files already in our own
                    // container) — read regardless, only balance a successful
                    // start with a stop.
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                    do {
                        pendingImportData = try Data(contentsOf: url)
                        presentAfterPickerDismissal { showImportConfirmation = true }
                    } catch {
                        importErrorMessage = error.localizedDescription
                        presentAfterPickerDismissal { showImportError = true }
                    }
                case .failure(let error):
                    importErrorMessage = error.localizedDescription
                    presentAfterPickerDismissal { showImportError = true }
                }
            }
            .alert("Import Settings?", isPresented: $showImportConfirmation) {
                Button("Import", role: .destructive) {
                    guard let data = pendingImportData else { return }
                    Task {
                        do {
                            let decoder = JSONDecoder()
                            decoder.dateDecodingStrategy = .iso8601
                            let backup = try decoder.decode(SettingsBackup.self, from: data)
                            await appModel.importSettingsBackup(backup)
                            showImportSuccess = true
                        } catch {
                            importErrorMessage = error.localizedDescription
                            showImportError = true
                        }
                        pendingImportData = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingImportData = nil
                }
            } message: {
                Text("This will replace your current settings with the imported backup. This cannot be undone.")
            }
            .alert("Import Successful", isPresented: $showImportSuccess) {
                Button("OK") {}
            } message: {
                Text("Settings have been restored from backup.")
            }
            .alert("Import Failed", isPresented: $showImportError) {
                Button("OK") {}
            } message: {
                Text(importErrorMessage)
            }
            .alert("Clear Saved Enhancements?", isPresented: $showEnhancementsClearConfirmation) {
                Button("Disable & Clear Data", role: .destructive) {
                    appModel.rememberImageEnhancements = false
                    Task { await appModel.clearImageEnhancementData() }
                }
                Button("Disable & Keep Data") {
                    appModel.rememberImageEnhancements = false
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Would you like to clear existing remembered enhancements? Keeping the data allows them to be restored if you re-enable this setting.")
            }
        }
    }

    /// Role-model dropdown: "Automatic" (first installed) plus every installed
    /// model. A preference naming a since-deleted model is shown as missing so
    /// the picker doesn't render an empty selection.
    @ViewBuilder
    private func depthModelPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Automatic").tag("")
            ForEach(depthModels.installedNames, id: \.self) { name in
                Text(DepthModelManager.displayName(for: name)).tag(name)
            }
            if !selection.wrappedValue.isEmpty, !depthModels.installedNames.contains(selection.wrappedValue) {
                Text("\(DepthModelManager.displayName(for: selection.wrappedValue)) (missing)")
                    .tag(selection.wrappedValue)
            }
        }
        .pickerStyle(.menu)
    }

    // MARK: - Window Groups

    /// Number of open windows a group would capture right now. Extracted (like
    /// the whole section below) because inlining it in the `List` blew past the
    /// type-checker's budget for that expression.
    private var openWindowCount: Int {
        appModel.openWindowEntries.count
    }

    @ViewBuilder
    private var windowGroupsSection: some View {
        Section {
            Button("Save Current Windows") {
                newGroupName = ""
                showSaveGroupAlert = true
            }
            .disabled(openWindowCount == 0)

            if appModel.savedWindowGroups.isEmpty {
                Text("No saved window groups")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appModel.savedWindowGroups) { group in
                    windowGroupRow(group)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        appModel.deleteSavedWindowGroup(appModel.savedWindowGroups[index])
                    }
                }
            }
        } header: {
            Text("Window Groups")
        } footer: {
            Text("Saves every open pop-out window — photos, videos, RoboFrame slideshows and pinned web pages — and restores each one at the size it was saved at.")
        }
    }

    @ViewBuilder
    private func windowGroupRow(_ group: SavedWindowGroup) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(group.name)
                Text("\(group.contentSummary) \u{00B7} \(group.savedDate, style: .date)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rename") {
                renamingGroup = group
                renameGroupName = group.name
                showRenameGroupAlert = true
            }
            .buttonStyle(.borderless)
            Button("Restore All") {
                appModel.restoreWindowGroup(group)
            }
            .buttonStyle(.borderless)
            Button("Restore...") {
                restoreSheetGroup = group
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Presenting an alert directly from the fileImporter completion handler
    /// races the picker's dismissal animation and the alert silently never
    /// appears (the tap seems to "do nothing"). Defer the presentation until
    /// the picker is gone.
    private func presentAfterPickerDismissal(_ present: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            present()
        }
    }

    private func importFromDocuments() {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileManager = FileManager.default

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: documentsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let jsonFiles = contents
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { a, b in
                    let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return dateA > dateB
                }

            guard let firstJSON = jsonFiles.first else {
                importErrorMessage = "No JSON files found in Documents folder. Place a settings backup file there and try again."
                showImportError = true
                return
            }

            let data = try Data(contentsOf: firstJSON)
            pendingImportData = data
            showImportConfirmation = true
            AppLogger.settings.info("Found settings backup in Documents: \(firstJSON.lastPathComponent, privacy: .public)")
        } catch {
            importErrorMessage = error.localizedDescription
            showImportError = true
        }
    }

    private func testConnection() async {
        // Simple connection test - try to fetch first page
        do {
            _ = try await appModel.imageSource.fetchImages(page: 0, pageSize: 1)
            AppLogger.settings.info("Connection successful!")
        } catch {
            AppLogger.settings.error("Connection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func backupDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func formatSlideshowDelay(_ seconds: TimeInterval) -> String {
        let intSeconds = Int(seconds)
        if intSeconds >= 60 {
            let minutes = intSeconds / 60
            let remainingSeconds = intSeconds % 60
            if remainingSeconds == 0 {
                return "\(minutes) min"
            } else {
                return "\(minutes) min \(remainingSeconds) sec"
            }
        } else {
            return "\(intSeconds) seconds"
        }
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let commitHash = Bundle.main.infoDictionary?["CommitHash"] as? String
        if let commitHash, !commitHash.isEmpty, commitHash != "unknown" {
            return "\(version) (\(commitHash))"
        }
        return version
    }

    /// Whether any secondary (non-main) window scenes are currently connected
    private var hasSecondaryWindows: Bool {
        let mainSession = sceneDelegate?.windowScene?.session
        return UIApplication.shared.connectedScenes.contains { scene in
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.session.role == .windowApplication else {
                return false
            }
            return windowScene.session !== mainSession
        }
    }

    /// Close all secondary windows (photo, video, shared) by requesting scene destruction
    private func closeAllSecondaryWindows() {
        let mainSession = sceneDelegate?.windowScene?.session
        let secondaryScenes = UIApplication.shared.connectedScenes.compactMap { scene -> UISceneSession? in
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.session.role == .windowApplication,
                  windowScene.session !== mainSession else {
                return nil
            }
            return windowScene.session
        }

        for session in secondaryScenes {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }

        AppLogger.settings.info("Closed \(secondaryScenes.count, privacy: .public) secondary windows")
    }
}
