/*
 Spatial Stash - Settings Tab View

 Settings view with server configuration and source selection.
 */

import SwiftUI

struct SettingsTabView: View {
    @Environment(AppModel.self) private var appModel

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

                Section {
                    Button("Refresh All Content") {
                        print("[Settings] Refresh button pressed, source: \(appModel.mediaSourceType)")
                        Task {
                            print("[Settings] Starting gallery refresh...")
                            await appModel.loadInitialGallery()
                            print("[Settings] Gallery refresh complete, images: \(appModel.galleryImages.count)")
                            await appModel.loadInitialVideos()
                            print("[Settings] Video refresh complete, videos: \(appModel.galleryVideos.count)")
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
        }
    }

    private func testConnection() async {
        // Simple connection test - try to fetch first page
        do {
            _ = try await appModel.imageSource.fetchImages(page: 0, pageSize: 1)
            print("Connection successful!")
        } catch {
            print("Connection failed: \(error)")
        }
    }
}
