/*
 Spatial Stash - Local Tab View with Folder Hierarchy

 Container for browsing local media files organized in folder hierarchies.
 Shows Photos and Videos at top level, with navigation tiles for subfolders.
 */

import os
import SwiftUI

struct LocalTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedFolderPath: [String] = []
    @State private var selectedImage: GalleryImage? = nil

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
            if selectedFolderPath.isEmpty {
                // Show folder picker at root
                FolderListView(isRootLevel: true) { folder in
                    selectedFolderPath = [folder.rawValue]
                }
            } else {
                // Show media list with folder hierarchy
                LocalMediaListView(
                    folderPath: selectedFolderPath,
                    onBack: {
                        if selectedFolderPath.count > 1 {
                            selectedFolderPath.removeLast()
                        } else {
                            selectedFolderPath = []
                        }
                    },
                    onSelectFolder: { folderName in
                        selectedFolderPath.append(folderName)
                    },
                    onSelectImage: { image in
                        selectedImage = image
                    }
                )
            }
        }
        .environment(appModel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: appModel.localTabReselected) { oldValue, newValue in
            // When Local tab is re-tapped while already viewing it, close folders and return to root
            if !selectedFolderPath.isEmpty {
                selectedFolderPath = []
                selectedImage = nil
            }
        }
    }
}

// MARK: - Folder List View

struct FolderListView: View {
    let isRootLevel: Bool
    var onSelectFolder: (LocalTabView.LocalMediaFolder) -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("Local Media")
                .font(.headline)
                .padding(.top, 20)

            ForEach(LocalTabView.LocalMediaFolder.allCases) { folder in
                Button {
                    onSelectFolder(folder)
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
            .safeAreaPadding(.bottom)
        }
        .padding()
    }
}

// MARK: - Local Media List View with Hierarchy

struct LocalMediaListView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?

    let folderPath: [String]
    let onBack: () -> Void
    let onSelectFolder: (String) -> Void
    let onSelectImage: (GalleryImage) -> Void

    @State private var mediaFiles: [LocalMediaFile] = []
    @State private var subfolders: [String] = []
    @State private var isLoading = true
    @State private var selectedImage: GalleryImage? = nil
    @State private var isShowingLocalVideo = false

    let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 250), spacing: 16)
    ]

    var currentFolderName: String {
        folderPath.last ?? "Media"
    }

    var currentPath: String {
        folderPath.joined(separator: " / ")
    }

    var body: some View {
        Group {
            if isShowingLocalVideo, appModel.selectedVideo != nil {
                VideoPlayerView()
            } else if !appModel.openImagesInSeparateWindows, let image = selectedImage {
                PushedPictureView(image: image, appModel: appModel, onDismiss: {
                    selectedImage = nil
                })
            } else {
                VStack(spacing: 0) {
                    // Breadcrumb/Path display
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Local / \(currentPath)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Text(currentFolderName)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.secondary.opacity(0.05))

                    // Content
                    if isLoading {
                        VStack(spacing: 20) {
                            ProgressView()
                                .scaleEffect(2)
                            Text("Loading \(currentFolderName.lowercased())...")
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 16) {
                                // Back/Up navigation tile
                                if folderPath.count >= 1 {
                                    Button {
                                        onBack()
                                    } label: {
                                        VStack(spacing: 12) {
                                            Image(systemName: "arrow.turn.left.up")
                                                .font(.title)
                                                .foregroundColor(.accentColor)
                                            Text("Up")
                                                .font(.caption)
                                                .foregroundColor(.primary)
                                        }
                                        .frame(height: 150)
                                        .frame(maxWidth: .infinity)
                                        .background(Color.secondary.opacity(0.2))
                                        .cornerRadius(12)
                                    }
                                    .buttonStyle(.plain)
                                }

                                // Subfolder tiles
                                ForEach(subfolders, id: \.self) { subfolder in
                                    Button {
                                        onSelectFolder(subfolder)
                                    } label: {
                                        VStack(spacing: 12) {
                                            Image(systemName: "folder")
                                                .font(.title)
                                                .foregroundColor(.orange)
                                            Text(subfolder)
                                                .font(.caption)
                                                .foregroundColor(.primary)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.center)
                                        }
                                        .frame(height: 150)
                                        .frame(maxWidth: .infinity)
                                        .background(Color.secondary.opacity(0.1))
                                        .cornerRadius(12)
                                    }
                                    .buttonStyle(.plain)
                                }

                                // Media file tiles
                                ForEach(mediaFiles, id: \.id) { file in
                                    LocalMediaThumbnailView(file: file) {
                                        if folderPath.first == "Photos" {
                                            let image = GalleryImage(
                                                id: file.id,
                                                url: file.url,
                                                title: file.name
                                            )
                                            if appModel.openImagesInSeparateWindows {
                                                appModel.enqueuePhotoWindowOpen(image)
                                            } else {
                                                selectedImage = image
                                            }
                                        } else if folderPath.first == "Videos" {
                                            let video = GalleryVideo(
                                                stashId: file.url.absoluteString,
                                                thumbnailURL: file.url,
                                                streamURL: file.url,
                                                title: file.name
                                            )
                                            appModel.selectVideoForDetail(video)
                                            isShowingLocalVideo = true
                                        }
                                    }
                                }

                                // Empty state message
                                if mediaFiles.isEmpty && subfolders.isEmpty {
                                    VStack(spacing: 20) {
                                        Image(systemName: folderPath.first == "Photos" ? "photo" : "video")
                                            .font(.system(size: 48))
                                            .foregroundColor(.secondary)
                                        Text("No files or folders found")
                                            .font(.callout)
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                }
                            }
                            .padding()
                        }
                    }
                }
                .onAppear {
                    loadContent()
                }
                .onChange(of: folderPath) { oldPath, newPath in
                    loadContent()
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
        .onChange(of: appModel.isShowingVideoDetail) { _, isShowing in
            if !isShowing {
                isShowingLocalVideo = false
            }
        }
        .onChange(of: appModel.openImagesInSeparateWindows) { _, isEnabled in
            if isEnabled {
                selectedImage = nil
            }
        }
    }

    private func loadContent() {
        isLoading = true
        Task {
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            
            // Build the current directory path
            var currentDir = documentsDir
            for component in folderPath {
                currentDir = currentDir.appendingPathComponent(component, isDirectory: true)
            }

            // Verify directory exists
            let fileManager = FileManager.default
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: currentDir.path, isDirectory: &isDir), isDir.boolValue else {
                AppLogger.localMedia.error("Directory does not exist: \(currentDir.path, privacy: .private)")
                await MainActor.run {
                    subfolders = []
                    mediaFiles = []
                    isLoading = false
                }
                return
            }

            // Scan for subfolders and media files
            let result = scanDirectoryContent(at: currentDir, parentPath: currentDir)

            await MainActor.run {
                subfolders = result.folders.sorted()
                mediaFiles = result.mediaItems.sorted { $0.createdDate > $1.createdDate }
                isLoading = false
            }
        }
    }

    private func scanDirectoryContent(at directory: URL, parentPath: URL? = nil) -> (folders: [String], mediaItems: [LocalMediaFile]) {
        let fileManager = FileManager.default
        var folders: [String] = []
        var mediaItems: [LocalMediaFile] = []

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            AppLogger.localMedia.warning("Failed to create enumerator for: \(directory.path, privacy: .private)")
            return (folders, mediaItems)
        }

        let allURLs = enumerator.allObjects.compactMap { $0 as? URL }
        
        for fileURL in allURLs {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
                let isDirectory = resourceValues.isDirectory ?? false
                let folderName = fileURL.lastPathComponent
                
                // Skip system folders and current directory markers
                if folderName.hasPrefix(".") || folderName == "." || folderName == ".." {
                    continue
                }
                
                // Ensure we're not recursively listing the parent directory
                if let parentPath = parentPath, fileURL.standardizedFileURL == parentPath.standardizedFileURL {
                    continue
                }
                
                if isDirectory {
                    folders.append(folderName)
                } else if let mediaFile = createMediaFile(from: fileURL) {
                    mediaItems.append(mediaFile)
                }
            } catch {
                AppLogger.localMedia.error("Failed to read resource values for \(fileURL.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }

        return (folders, mediaItems)
    }

    private func createMediaFile(from url: URL) -> LocalMediaFile? {
        let imageExtensions = Set(["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif", "jxl"])
        let videoExtensions = Set(["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "3gp"])

        let fileExt = url.pathExtension.lowercased()
        let isImage = imageExtensions.contains(fileExt)
        let isVideo = videoExtensions.contains(fileExt)

        guard isImage || isVideo else { return nil }

        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
        let createdDate = resourceValues?.creationDate ?? Date()
        let modifiedDate = resourceValues?.contentModificationDate ?? Date()
        let fileSize = resourceValues?.fileSize ?? 0

        return LocalMediaFile(
            id: UUID(),
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            type: isImage ? .image : .video,
            createdDate: createdDate,
            modifiedDate: modifiedDate,
            fileSize: Int64(fileSize)
        )
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
        VStack(spacing: 0) {
            ZStack {
                Color.secondary.opacity(0.2)

                if let loadedImage {
                    Image(uiImage: loadedImage)
                        .resizable()
                        .scaledToFill()
                } else if isLoading {
                    ProgressView()
                } else {
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
            .frame(height: 150)

            // Filename bar
            Text(file.name)
                .font(.caption)
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.black)
        }
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
