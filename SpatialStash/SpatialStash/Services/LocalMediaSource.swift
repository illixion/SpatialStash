/*
 Spatial Stash - Local Media Source

 Scans the app's Documents folder for local images and videos.
 Files appear in the Files app under "On My Apple Vision Pro" > "Spatial Stash".
 */

import Foundation
import UniformTypeIdentifiers

/// Represents a local media file
struct LocalMediaFile: Identifiable {
    let id: UUID
    let url: URL
    let name: String
    let type: LocalMediaType
    let createdDate: Date
    let modifiedDate: Date
    let fileSize: Int64

    enum LocalMediaType {
        case image
        case video
    }
}

/// Service for managing local media files in the app's Documents folder
actor LocalMediaSource {
    static let shared = LocalMediaSource()

    // Supported file types
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif"
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "3gp"
    ]

    private static let imageMIMETypes: Set<String> = [
        "image/jpeg", "image/png", "image/heic", "image/heif", "image/gif",
        "image/webp", "image/bmp", "image/tiff"
    ]

    private static let videoMIMETypes: Set<String> = [
        "video/mp4", "video/x-m4v", "video/quicktime", "video/x-matroska",
        "video/webm", "video/x-msvideo", "video/x-ms-wmv", "video/x-flv", "video/3gpp"
    ]

    /// Get the Documents folder URL where users can add files
    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Create subdirectories for organizing imports and placeholder file
    func ensureDirectoriesExist() {
        let fileManager = FileManager.default
        let photosDir = documentsDirectory.appendingPathComponent("Photos", isDirectory: true)
        let videosDir = documentsDirectory.appendingPathComponent("Videos", isDirectory: true)

        try? fileManager.createDirectory(at: photosDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: videosDir, withIntermediateDirectories: true)

        // Create placeholder file so the folder shows up in Files app
        createPlaceholderFileIfNeeded()
    }

    /// Create a placeholder file to ensure the folder appears in the Files app
    private func createPlaceholderFileIfNeeded() {
        let placeholderURL = documentsDirectory.appendingPathComponent("Place media files here.txt")
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: placeholderURL.path) else { return }

        let placeholderContent = """
        Spatial Stash - Local Media Import

        Add your photos and videos to this folder to view them in the app.

        Supported formats:
        - Photos: JPG, PNG, HEIC, GIF, WebP, BMP, TIFF
        - Videos: MP4, MOV, MKV, WebM, AVI

        You can organize files into the Photos and Videos subfolders,
        or place them directly here.

        To import stereoscopic 3D videos, use the Stash server integration
        with appropriate tags (e.g., "stereoscopic", "SBS", "OU").
        """

        try? placeholderContent.write(to: placeholderURL, atomically: true, encoding: .utf8)
    }

    /// Scan for all local media files
    func scanAllMedia() -> [LocalMediaFile] {
        ensureDirectoriesExist()
        return scanDirectory(documentsDirectory, recursive: true)
    }

    /// Scan for local images
    func scanImages() -> [LocalMediaFile] {
        scanAllMedia().filter { $0.type == .image }
    }

    /// Scan for local videos
    func scanVideos() -> [LocalMediaFile] {
        scanAllMedia().filter { $0.type == .video }
    }

    /// Scan a directory for media files
    private func scanDirectory(_ directory: URL, recursive: Bool) -> [LocalMediaFile] {
        let fileManager = FileManager.default
        var mediaFiles: [LocalMediaFile] = []

        print("[LocalMediaSource] Scanning directory: \(directory.path)")

        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey,
            .contentTypeKey
        ]

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            print("[LocalMediaSource] Failed to create enumerator for \(directory.path)")
            return []
        }

        for case let fileURL as URL in enumerator {
            if let mediaFile = createMediaFile(from: fileURL) {
                mediaFiles.append(mediaFile)
            }
        }

        print("[LocalMediaSource] Found \(mediaFiles.count) media files")

        // Sort by creation date (newest first), falling back to modification date
        return mediaFiles.sorted { $0.createdDate > $1.createdDate }
    }

    /// Create a LocalMediaFile from a URL
    private func createMediaFile(from url: URL) -> LocalMediaFile? {
        // Get resource values
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileSizeKey,
            .contentTypeKey
        ]

        guard let resourceValues = try? url.resourceValues(forKeys: resourceKeys) else {
            return nil
        }

        // Skip directories
        if resourceValues.isDirectory == true {
            return nil
        }

        let ext = url.pathExtension.lowercased()
        let type: LocalMediaFile.LocalMediaType

        // Determine type by extension first
        if Self.imageExtensions.contains(ext) {
            type = .image
        } else if Self.videoExtensions.contains(ext) {
            type = .video
        } else {
            // Try content type as fallback
            if let contentType = resourceValues.contentType {
                if contentType.conforms(to: .image) {
                    type = .image
                } else if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
                    type = .video
                } else {
                    return nil
                }
            } else if let uti = UTType(filenameExtension: ext) {
                if uti.conforms(to: .image) {
                    type = .image
                } else if uti.conforms(to: .movie) || uti.conforms(to: .video) {
                    type = .video
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }

        let createdDate = resourceValues.creationDate ?? resourceValues.contentModificationDate ?? Date()
        let modifiedDate = resourceValues.contentModificationDate ?? Date()
        let fileSize = Int64(resourceValues.fileSize ?? 0)

        let mediaFile = LocalMediaFile(
            id: UUID(),
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            type: type,
            createdDate: createdDate,
            modifiedDate: modifiedDate,
            fileSize: fileSize
        )

        print("[LocalMediaSource] Found \(type == .image ? "image" : "video"): \(url.lastPathComponent), created: \(createdDate)")

        return mediaFile
    }
}

// MARK: - Image Source Conformance

/// ImageSource implementation for local files
final class LocalImageSource: ImageSource, @unchecked Sendable {
    func fetchImages(page: Int, pageSize: Int) async throws -> ImageFetchResult {
        print("[LocalImageSource] Fetching images page \(page), pageSize \(pageSize)")

        let allImages = await LocalMediaSource.shared.scanImages()
        print("[LocalImageSource] Total images found: \(allImages.count)")

        let startIndex = page * pageSize
        let endIndex = min(startIndex + pageSize, allImages.count)

        guard startIndex < allImages.count else {
            print("[LocalImageSource] No more images (startIndex \(startIndex) >= count \(allImages.count))")
            return ImageFetchResult(images: [], hasMore: false, totalCount: allImages.count)
        }

        let pageImages = Array(allImages[startIndex..<endIndex])

        let galleryImages = pageImages.map { file in
            GalleryImage(
                thumbnailURL: file.url,
                fullSizeURL: file.url,
                title: file.name
            )
        }

        print("[LocalImageSource] Returning \(galleryImages.count) images for page \(page)")

        return ImageFetchResult(
            images: galleryImages,
            hasMore: endIndex < allImages.count,
            totalCount: allImages.count
        )
    }
}

// MARK: - Video Source Conformance

/// VideoSource implementation for local files
final class LocalVideoSource: VideoSource, @unchecked Sendable {
    func fetchVideos(page: Int, pageSize: Int) async throws -> VideoFetchResult {
        let allVideos = await LocalMediaSource.shared.scanVideos()

        let startIndex = page * pageSize
        let endIndex = min(startIndex + pageSize, allVideos.count)

        guard startIndex < allVideos.count else {
            return VideoFetchResult(videos: [], hasMore: false, totalCount: allVideos.count)
        }

        let pageVideos = Array(allVideos[startIndex..<endIndex])

        let galleryVideos = pageVideos.map { file in
            GalleryVideo(
                stashId: file.url.absoluteString,
                thumbnailURL: file.url, // Will use video frame as thumbnail
                streamURL: file.url,
                title: file.name,
                duration: nil, // Could extract with AVAsset if needed
                isStereoscopic: false,
                stereoscopicFormat: nil,
                sourceWidth: nil,
                sourceHeight: nil,
                eyesReversed: false
            )
        }

        return VideoFetchResult(
            videos: galleryVideos,
            hasMore: endIndex < allVideos.count,
            totalCount: allVideos.count
        )
    }
}
