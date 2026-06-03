/*
 Spatial Stash - Photo Window Value

 Wrapper around GalleryImage with a unique instance ID for pop-out windows.
 Each pop-out window gets a unique value so visionOS always creates a new window
 rather than reusing an existing one with the same image.
 */

import Foundation

struct PhotoWindowValue: Identifiable, Codable, Hashable {
    /// Unique per window instance — ensures visionOS treats each opening as a new window
    let id: UUID
    var image: GalleryImage

    /// Whether this window was opened via pushWindow (back button dismisses)
    /// vs openWindow (standalone pop-out with gallery button)
    var wasPushed: Bool

    /// User's last-resolved window size, written back as the window is resized.
    /// Persisted by visionOS into the scene-restoration archive so a wall-snapped
    /// pop-out can be restored to its custom size after a cold relaunch. `nil` on
    /// fresh opens — those size from the image aspect ratio / scene default.
    var restoredSize: CodableSize?

    init(image: GalleryImage, wasPushed: Bool = false) {
        self.id = UUID()
        self.image = image
        self.wasPushed = wasPushed
        self.restoredSize = nil
    }
}
