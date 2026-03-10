/*
 Spatial Stash - Video Window Value

 Wrapper around GalleryVideo with a unique instance ID for pop-out video windows.
 Snapshots the stereoscopic mode and 3D settings at pop-out time so the window
 is independent of the main window's video state.
 */

import Foundation

struct VideoWindowValue: Identifiable, Codable, Hashable {
    /// Unique per window instance — ensures visionOS treats each opening as a new window
    let id: UUID
    var video: GalleryVideo

    /// Snapshot of stereoscopic override at pop-out time (nil = auto-detect, true = 3D, false = 2D)
    var stereoscopicOverride: Bool?

    /// Snapshot of custom 3D settings at pop-out time
    var video3DSettings: Video3DSettings?

    init(video: GalleryVideo, stereoscopicOverride: Bool? = nil, video3DSettings: Video3DSettings? = nil) {
        self.id = UUID()
        self.video = video
        self.stereoscopicOverride = stereoscopicOverride
        self.video3DSettings = video3DSettings
    }
}
