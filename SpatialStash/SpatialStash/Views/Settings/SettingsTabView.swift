/*
 Spatial Stash - Settings Tab View

 Settings view with server configuration and source selection.
 */

import os
import SwiftUI
import UniformTypeIdentifiers

struct SettingsTabView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?
    @Environment(\.openWindow) private var openWindow
    @State private var imageCacheStats: (fileCount: Int, totalSize: Int64) = (0, 0)
    @State private var videoCacheStats: (fileCount: Int, totalSize: Int64) = (0, 0)
    @State private var backgroundRemovalCacheStats: (fileCount: Int, totalSize: Int64) = (0, 0)
    @State private var gifHEVCCacheStats: (fileCount: Int, totalSize: Int64) = (0, 0)
    @State private var isClearingImageCache = false
    @State private var isClearingVideoCache = false
    @State private var isClearingBackgroundRemovalCache = false
    @State private var isClearingGIFHEVCCache = false
    @State private var showSaveGroupAlert = false
    @State private var newGroupName = ""
    @State private var showRenameGroupAlert = false
    @State private var renamingGroup: SavedWindowGroup?
    @State private var renameGroupName = ""
    @State private var restoreSheetGroup: SavedWindowGroup?
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
                    Toggle("Rounded Corners", isOn: $appModel.roundedCorners)

                    Toggle("Open media in new windows", isOn: $appModel.openMediaInNewWindows)

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

                    Picker("Max Image Resolution", selection: $appModel.maxImageResolution) {
                        ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Auto-hide Controls", selection: $appModel.autoHideDelay) {
                        ForEach(AppModel.autoHideDelayOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Slideshow") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Delay Between Images")
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
                }

                Section("Window Groups") {
                    Button("Save Current Windows") {
                        newGroupName = ""
                        showSaveGroupAlert = true
                    }
                    .disabled(appModel.openPopOutWindows.isEmpty)

                    if appModel.savedWindowGroups.isEmpty {
                        Text("No saved window groups")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(appModel.savedWindowGroups) { group in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(group.name)
                                    Text("\(group.images.count) windows \u{00B7} \(group.savedDate, style: .date)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Rename") {
                                    renamingGroup = group
                                    renameGroupName = group.name
                                    showRenameGroupAlert = true
                                }
                                .buttonStyle(.borderless)
                                Button("Restore All") {
                                    appModel.restoreAllImagesInGroup(group)
                                }
                                .buttonStyle(.borderless)
                                Button("Restore...") {
                                    restoreSheetGroup = group
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                appModel.deleteSavedWindowGroup(appModel.savedWindowGroups[index])
                            }
                        }
                    }
                }

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

                Section("Cache") {
                    HStack {
                        Text("Images")
                        Spacer()
                        Text("\(imageCacheStats.fileCount) items, \(formatBytes(imageCacheStats.totalSize))")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Videos")
                        Spacer()
                        Text("\(videoCacheStats.fileCount) items, \(formatBytes(videoCacheStats.totalSize))")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Background Removal")
                        Spacer()
                        Text("\(backgroundRemovalCacheStats.fileCount) items, \(formatBytes(backgroundRemovalCacheStats.totalSize))")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Animated GIFs")
                        Spacer()
                        Text("\(gifHEVCCacheStats.fileCount) items, \(formatBytes(gifHEVCCacheStats.totalSize))")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Total")
                        Spacer()
                        Text(formatBytes(imageCacheStats.totalSize + videoCacheStats.totalSize + backgroundRemovalCacheStats.totalSize + gifHEVCCacheStats.totalSize))
                            .foregroundColor(.secondary)
                            .fontWeight(.medium)
                    }
                    Button(role: .destructive) {
                        isClearingImageCache = true
                        Task {
                            await clearImageCache()
                            await refreshCacheStats()
                            isClearingImageCache = false
                        }
                    } label: {
                        if isClearingImageCache {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Clearing...")
                            }
                        } else {
                            Text("Clear Image Cache")
                        }
                    }
                    .disabled(isClearingImageCache || imageCacheStats.fileCount == 0)

                    Button(role: .destructive) {
                        isClearingVideoCache = true
                        Task {
                            await clearVideoCache()
                            await refreshCacheStats()
                            isClearingVideoCache = false
                        }
                    } label: {
                        if isClearingVideoCache {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Clearing...")
                            }
                        } else {
                            Text("Clear Video Cache")
                        }
                    }
                    .disabled(isClearingVideoCache || videoCacheStats.fileCount == 0)

                    Button(role: .destructive) {
                        isClearingBackgroundRemovalCache = true
                        Task {
                            await clearBackgroundRemovalCache()
                            await refreshCacheStats()
                            isClearingBackgroundRemovalCache = false
                        }
                    } label: {
                        if isClearingBackgroundRemovalCache {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Clearing...")
                            }
                        } else {
                            Text("Clear Background Removal Cache")
                        }
                    }
                    .disabled(isClearingBackgroundRemovalCache || backgroundRemovalCacheStats.fileCount == 0)

                    Button(role: .destructive) {
                        isClearingGIFHEVCCache = true
                        Task {
                            await DiskGIFHEVCCache.shared.clearCache()
                            await refreshCacheStats()
                            isClearingGIFHEVCCache = false
                        }
                    } label: {
                        if isClearingGIFHEVCCache {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Clearing...")
                            }
                        } else {
                            Text("Clear Animated GIF Cache")
                        }
                    }
                    .disabled(isClearingGIFHEVCCache || gifHEVCCacheStats.fileCount == 0)
                }

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
                }

                Section("Developer") {
                    Toggle("Show Debug Console", isOn: Binding(
                        get: { appModel.showDebugConsole },
                        set: { newValue in
                            appModel.showDebugConsole = newValue
                            Task {
                                try? await Task.sleep(for: .milliseconds(50))
                                if newValue {
                                    LogStore.shared.startPolling()
                                } else {
                                    if appModel.selectedTab == .console {
                                        appModel.selectedTab = .settings
                                    }
                                    LogStore.shared.stopAndClear()
                                }
                            }
                        }
                    ))
                    if appModel.showDebugConsole {
                        Text("The Console tab shows app log messages in real time. Useful when Xcode is not connected.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Respect System Memory Alerts", isOn: $appModel.respectMemoryAlerts)
                    Text("When disabled, the app will not unload images or downscale windows in response to system memory pressure.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Lossy Texture Compression", isOn: $appModel.useLossyTextureCompression)
                    Text("Reduces GPU memory per image by ~2-4x using hardware lossy compression. Slight quality reduction. New images use the updated setting; existing windows are unaffected until reloaded.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button {
                        openWindow(id: "gpu-memory")
                    } label: {
                        Label("Open GPU Memory Monitor", systemImage: "memorychip")
                    }

                    Button("Close All Windows", role: .destructive) {
                        closeAllSecondaryWindows()
                    }
                    .disabled(!hasSecondaryWindows)
                }

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
                await refreshCacheStats()
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
                Text("Enter a name for this window group (\(appModel.openPopOutWindows.values.flatMap { $0 }.count) windows).")
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
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url) {
                        pendingImportData = data
                        showImportConfirmation = true
                    }
                case .failure(let error):
                    importErrorMessage = error.localizedDescription
                    showImportError = true
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

    private func testConnection() async {
        // Simple connection test - try to fetch first page
        do {
            _ = try await appModel.imageSource.fetchImages(page: 0, pageSize: 1)
            AppLogger.settings.info("Connection successful!")
        } catch {
            AppLogger.settings.error("Connection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshCacheStats() async {
        imageCacheStats = await DiskImageCache.shared.getCacheStats()
        videoCacheStats = await DiskVideoCache.shared.getCacheStats()
        backgroundRemovalCacheStats = await BackgroundRemovalCache.shared.getCacheStats()
        gifHEVCCacheStats = await DiskGIFHEVCCache.shared.getCacheStats()
    }

    private func clearImageCache() async {
        await ImageLoader.shared.clearCache()
    }

    private func clearVideoCache() async {
        await DiskVideoCache.shared.clearCache()
    }

    private func clearBackgroundRemovalCache() async {
        await BackgroundRemovalCache.shared.clearCache()
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
