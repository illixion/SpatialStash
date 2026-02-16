/*
 Spatial Stash - Gallery Image Model

 Represents an image in the gallery with thumbnail and full-size URLs.
 */

import Foundation

struct GalleryImage: Identifiable, Equatable, Hashable, Codable {
    let id: UUID
    let stashId: String?
    let thumbnailURL: URL
    let fullSizeURL: URL
    let title: String?
    var rating100: Int?
    var oCounter: Int?

    init(id: UUID = UUID(), stashId: String? = nil, thumbnailURL: URL, fullSizeURL: URL, title: String? = nil, rating100: Int? = nil, oCounter: Int? = nil) {
        self.id = id
        self.stashId = stashId
        self.thumbnailURL = thumbnailURL
        self.fullSizeURL = fullSizeURL
        self.title = title
        self.rating100 = rating100
        self.oCounter = oCounter
    }

    /// Convenience initializer when thumbnail and full-size are the same URL
    init(id: UUID = UUID(), stashId: String? = nil, url: URL, title: String? = nil, rating100: Int? = nil, oCounter: Int? = nil) {
        self.id = id
        self.stashId = stashId
        self.thumbnailURL = url
        self.fullSizeURL = url
        self.title = title
        self.rating100 = rating100
        self.oCounter = oCounter
    }
}
