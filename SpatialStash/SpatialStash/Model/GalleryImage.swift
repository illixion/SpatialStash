/*
 Spatial Stash - Gallery Image Model

 Represents an image in the gallery with thumbnail and full-size URLs.
 */

import Foundation

struct GalleryImage: Identifiable, Equatable, Hashable, Codable {
    let id: UUID
    let thumbnailURL: URL
    let fullSizeURL: URL
    let title: String?

    init(id: UUID = UUID(), thumbnailURL: URL, fullSizeURL: URL, title: String? = nil) {
        self.id = id
        self.thumbnailURL = thumbnailURL
        self.fullSizeURL = fullSizeURL
        self.title = title
    }

    /// Convenience initializer when thumbnail and full-size are the same URL
    init(id: UUID = UUID(), url: URL, title: String? = nil) {
        self.id = id
        self.thumbnailURL = url
        self.fullSizeURL = url
        self.title = title
    }
}
