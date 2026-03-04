/*
 Spatial Stash - Local Tab View

 Container for browsing local media files from the app Documents folder.
 Shows two folders: Photos and Videos.
 */

import os
import SwiftUI

struct LocalTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedFolder: LocalMediaFolder? = nil

    enum LocalMediaFolder: String, CaseIterable, Identifiable {
        case photos = "Photos"
        case videos = "Videos"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .photos: return "photo"
            case .videos: return "video"
            }
        }
    }

    var body: some View {
        Group {
            if let folder = selectedFolder {
                // Show media list for selected folder
                LocalMediaListView(folder: folder) {
                    selectedFolder = nil
                }
            } else {
                // Show folder picker
                VStack(spacing: 24) {
                    Text("Local Media")
                        .font(.headline)
                        .padding(.top, 20)

                    ForEach(LocalMediaFolder.allCases) { folder in
                        Button {
                            selectedFolder = folder
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: folder.systemImage)
                                    .font(.title2)
                                    .foregroundColor(.accentColor)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(folder.rawValue)
                                        .font(.headline)
                                    Text("Browse local \(folder.rawValue.lowercased())")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                            Text("Files are stored in the app's Documents folder")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(8)
                    }
                    .padding()
                }
                .padding()
            }
        }
        .environment(appModel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: appModel.localTabReselected) { oldValue, newValue in
            // When Local tab is re-tapped while already viewing it, close the folder view
            if selectedFolder != nil {
                selectedFolder = nil
            }
        }
    }
}

// MARK: - Local Media List View

struct LocalMediaListView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?
    @Environment(\.openWindow) private var openWindow

    let folder: LocalTabView.LocalMediaFolder
    let onBack: () -> Void

    @State private var mediaFiles: [LocalMediaFile] = []
    @State private var isLoading = true
    @State private var selectedImage: GalleryImage? = nil

    let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)
    ]

    var body: some View {
        Group {
            if let image = selectedImage {
                PushedPictureView(image: image, appModel: appModel, onDismiss: {
                    selectedImage = nil
                })
            } else {
                VStack(spacing: 0) {
                    // Back button
                    HStack {
                        Button {
                            onBack()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                            .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Text(folder.rawValue)
                            .font(.headline)

                        Spacer()
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.05))

                    // Content
                    if isLoading {
                        VStack(spacing: 20) {
                            ProgressView()
                                .scaleEffect(2)
                            Text("Loading \(folder.rawValue.lowercased())...")
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if mediaFiles.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: folder == .photos ? "photo" : "video")
                                .font(.system(size: 64))
                                .foregroundColor(.secondary)
                            Text("No \(folder.rawValue.lowercased()) found")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("Add files to the\n\(folder.rawValue) folder")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(mediaFiles, id: \.id) { file in
                                    LocalMediaThumbnailView(file: file) {
                                        if folder == .photos {
                                            // Open photo viewer for images
                                            let image = GalleryImage(
                                                id: file.id,
                                                url: file.url,
                                                title: file.name
                                            )
                                            selectedImage = image
                                        } else {
                                            // Videos - would need separate action
                                            // For now just log
                                            AppLogger.views.debug("Selected video: \(file.name, privacy: .private)")
                                        }
                                    }
                                }
                            }
                            .padding()
                        }
                    }
                }
                .onAppear {
                    scanMediaFiles()
                }
                .onAppear {
                    if let windowScene = resolvedWindowScene {
                        windowScene.requestGeometryUpdate(.Vision(
                            size: CGSize(width: 1200, height: 800),
                            resizingRestrictions: .freeform
                        ))
                    }
                }
            }
        }
        .environment(appModel)
    }

    private func scanMediaFiles() {
        isLoading = true
        Task {
            let allFiles = await LocalMediaSource.shared.scanAllMedia()
            let filtered = allFiles.filter { file in
                switch folder {
                case .photos:
                    return file.type == .image
                case .videos:
                    return file.type == .video
                }
            }
            await MainActor.run {
                mediaFiles = filtered
                isLoading = false
            }
        }
    }

    private var resolvedWindowScene: UIWindowScene? {
        if let sceneDelegate {
            return sceneDelegate.windowScene
        }

        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

// MARK: - Local Media Thumbnail View

struct LocalMediaThumbnailView: View {
    let file: LocalMediaFile
    var onTap: (() -> Void)? = nil

    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            // Background
            Color.secondary.opacity(0.2)

            if let loadedImage {
                // Display image
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
            } else {
                // Error state
                VStack(spacing: 8) {
                    Image(systemName: file.type == .image ? "photo" : "video")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    if loadFailed {
                        Text("Failed to load")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(width: 200, height: 200)
        .cornerRadius(12)
        .clipped()
        .contentShape(Rectangle())
        .hoverEffect(ScaleHoverEffect())
        .onTapGesture {
            onTap?()
        }
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        if let result = await ImageLoader.shared.loadThumbnailWithData(from: file.url) {
            loadedImage = cropToSquare(result.image)
        } else {
            AppLogger.views.warning("Failed to load thumbnail for local file: \(file.name, privacy: .private)")
            loadFailed = true
        }
        isLoading = false
    }

    private func cropToSquare(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let xOffset = (image.size.width - side) / 2
        let yOffset = (image.size.height - side) / 2

        let cropRect = CGRect(x: xOffset, y: yOffset, width: side, height: side)

        guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
            return image
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
