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

    /// Complete sibling list for prev/next navigation. Used by sources not backed
    /// by `appModel.galleryVideos` (e.g. the Local tab), so the window navigates
    /// this fixed list instead of the (Stash) app gallery. nil = fall back to the
    /// app gallery snapshot with lazy pagination.
    var galleryVideos: [GalleryVideo]?

    /// Snapshot of stereoscopic override at pop-out time (nil = auto-detect, true = 3D, false = 2D)
    var stereoscopicOverride: Bool?

    /// Snapshot of custom 3D settings at pop-out time
    var video3DSettings: Video3DSettings?

    /// Snapshot of real-time fake-3D intent at pop-out time
    var pseudo3DEnabled: Bool

    /// Snapshot of fake-3D depth tuning at pop-out time
    var pseudo3DSettings: Pseudo3DSettings?

    /// Whether this window was opened via pushWindow (back button dismisses)
    /// vs openWindow (standalone pop-out with gallery button)
    var wasPushed: Bool

    init(
        video: GalleryVideo,
        galleryVideos: [GalleryVideo]? = nil,
        stereoscopicOverride: Bool? = nil,
        video3DSettings: Video3DSettings? = nil,
        pseudo3DEnabled: Bool = false,
        pseudo3DSettings: Pseudo3DSettings? = nil,
        wasPushed: Bool = false
    ) {
        self.id = UUID()
        self.video = video
        self.galleryVideos = galleryVideos
        self.stereoscopicOverride = stereoscopicOverride
        self.video3DSettings = video3DSettings
        self.pseudo3DEnabled = pseudo3DEnabled
        self.pseudo3DSettings = pseudo3DSettings
        self.wasPushed = wasPushed
    }
}
