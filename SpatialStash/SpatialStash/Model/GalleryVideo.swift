/*
 Spatial Stash - Gallery Video Model

 Represents a video in the gallery with thumbnail and stream URLs.
 */

import Foundation

struct GalleryVideo: Identifiable, Equatable, Hashable {
    let id: UUID
    let stashId: String
    let thumbnailURL: URL
    let streamURL: URL
    let title: String?
    let duration: TimeInterval?

    init(
        id: UUID = UUID(),
        stashId: String,
        thumbnailURL: URL,
        streamURL: URL,
        title: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.stashId = stashId
        self.thumbnailURL = thumbnailURL
        self.streamURL = streamURL
        self.title = title
        self.duration = duration
    }

    /// Formatted duration string (e.g., "1:23:45" or "12:34")
    var formattedDuration: String? {
        guard let duration = duration else { return nil }

        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
