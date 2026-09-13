/*
 Hypnos - Shared Media Item Model

 Represents a media file received via the system share sheet.
 Codable+Hashable for SwiftUI WindowGroup window restoration.
 */

import Foundation
import UniformTypeIdentifiers

struct SharedMediaItem: Identifiable, Codable, Hashable {
    let id: String
    let cachedFileURL: URL
    let originalFileName: String
    let mediaType: SharedMediaType

    enum SharedMediaType: String, Codable {
        case image
        case video

        private static let imageExtensions: Set<String> = [
            "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif", "jxl"
        ]

        /// Kept in sync with `StreamableURLResolver.videoExtensions` — a
        /// container the players can handle must classify as `.video` here too,
        /// or it gets handed to the photo viewer and renders nothing.
        private static let videoExtensions: Set<String> = StreamableURLResolver.videoExtensions

        static func from(url: URL) -> SharedMediaType {
            let ext = url.pathExtension.lowercased()

            if imageExtensions.contains(ext) {
                return .image
            } else if videoExtensions.contains(ext) {
                return .video
            }

            // Fallback: ask the file system what this actually is. In-place and
            // file-provider shares routinely arrive with no usable extension, so
            // `UTType(filenameExtension:)` returns nil for them — resolving the
            // real content type is the only way those get classified at all.
            if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
               let type = classify(contentType) {
                return type
            }

            if let utType = UTType(filenameExtension: ext), let type = classify(utType) {
                return type
            }

            return .image
        }

        private static func classify(_ type: UTType) -> SharedMediaType? {
            if type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent) {
                return .video
            }
            if type.conforms(to: .image) { return .image }
            return nil
        }
    }

    /// Convert to GalleryImage for reusing PhotoWindowModel
    func asGalleryImage() -> GalleryImage {
        GalleryImage(url: cachedFileURL, title: originalFileName, source: .shared)
    }
}
