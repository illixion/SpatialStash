/*
 Spatial Stash - Saved Window Group

 A user-saved named group of photo windows for restoring arrangements.
 */

import Foundation

struct SavedWindowGroup: Codable, Identifiable {
    let id: UUID
    var name: String
    var images: [GalleryImage]
    let savedDate: Date

    init(name: String, images: [GalleryImage]) {
        self.id = UUID()
        self.name = name
        self.images = images
        self.savedDate = Date()
    }
}
