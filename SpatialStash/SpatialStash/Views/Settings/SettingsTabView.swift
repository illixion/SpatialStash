/*
 Spatial Stash - Settings Tab View

 Settings view with server configuration and source selection.
 */

import os
import SwiftUI

struct SettingsTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var imageCacheStats: (fileCount: Int, totalSize: Int64) = (0, 0)
    @State private var videoCacheStats: (fileCount: Int, totalSize: Int64) = (0, 0)
    @State private var isClearingImageCache = false
    @State private var isClearingVideoCache = false

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            List {
                Section("Media Source") {
                    Picker("Source", selection: $appModel.mediaSourceType) {
                        ForEach(MediaSourceType.allCases, id: \.self) { source in
                            Text(source.rawValue).tag(source)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Images per Page", selection: $appModel.pageSize) {
                        ForEach(AppModel.pageSizeOptions, id: \.self) { size in
                            Text("\(size)").tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Display") {
                    Picker("Auto-hide Controls", selection: $appModel.autoHideDelay) {
                        ForEach(AppModel.autoHideDelayOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
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
                        Text("Total")
                        Spacer()
                        Text(formatBytes(imageCacheStats.totalSize + videoCacheStats.totalSize))
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
                }

                Section {
                    Button("Refresh All Content") {
                        AppLogger.settings.debug("Refresh button pressed, source: \(appModel.mediaSourceType.rawValue, privacy: .public)")
                        Task {
                            AppLogger.settings.debug("Starting gallery refresh...")
                            await appModel.loadInitialGallery()
                            AppLogger.settings.debug("Gallery refresh complete, images: \(appModel.galleryImages.count, privacy: .public)")
                            await appModel.loadInitialVideos()
                            AppLogger.settings.debug("Video refresh complete, videos: \(appModel.galleryVideos.count, privacy: .public)")
                        }
                    }
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
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .task {
                await refreshCacheStats()
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
    }

    private func clearImageCache() async {
        await ImageLoader.shared.clearCache()
    }

    private func clearVideoCache() async {
        await DiskVideoCache.shared.clearCache()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
