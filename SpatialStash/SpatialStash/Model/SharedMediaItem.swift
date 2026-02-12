/*
 Spatial Stash - Shared Media Item Model

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

        static func from(url: URL) -> SharedMediaType {
            let ext = url.pathExtension.lowercased()
            let imageExtensions: Set<String> = [
                "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif"
            ]
            let videoExtensions: Set<String> = [
                "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "3gp"
            ]

            if imageExtensions.contains(ext) {
                return .image
            } else if videoExtensions.contains(ext) {
                return .video
            }

            // Fallback: use UTType conformance
            if let utType = UTType(filenameExtension: ext) {
                if utType.conforms(to: .image) { return .image }
                if utType.conforms(to: .movie) || utType.conforms(to: .video) { return .video }
            }

            return .image
        }
    }

    /// Convert to GalleryImage for reusing PhotoWindowModel
    func asGalleryImage() -> GalleryImage {
        GalleryImage(url: cachedFileURL, title: originalFileName)
    }
}
