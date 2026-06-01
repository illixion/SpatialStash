/*
 Spatial Stash - Gallery Slideshow Source Override

 Transient override passed from a photo viewer's slideshow button to the
 gallery-mode remote viewer it launches. Carries the originating window's
 image source and filter snapshot so the slideshow iterates over the same
 set of images the user was browsing (e.g. a specific local folder), not
 the app-wide Stash source.
 */

import Foundation

struct GallerySlideshowSourceOverride {
    let imageSource: any ImageSource
    let filter: ImageFilterCriteria?
}

/// Transient override passed from the video viewer's slideshow button to the
/// video-mode remote viewer it launches. Carries the video source and scene
/// filter snapshot so the slideshow iterates over the same set of videos.
struct VideoSlideshowSourceOverride {
    let videoSource: any VideoSource
    let filter: SceneFilterCriteria?
}
