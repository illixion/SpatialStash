/*
 Spatial Stash - Gallery Video Model

 Represents a video in the gallery with thumbnail and stream URLs.
 */

import Foundation

struct GalleryVideo: Identifiable, Equatable, Hashable, Codable {
    let id: UUID
    let stashId: String
    let thumbnailURL: URL
    /// Preferred playback URL. For Stash-hosted WebM this may be a server-side
    /// MP4/HLS transcode because visionOS WebKit WebM support depends on codec.
    let streamURL: URL
    /// Original direct Stash stream URL, used as fallback when a preferred
    /// server-side transcode cannot be played.
    let fallbackStreamURL: URL?
    /// Short auto-generated Stash scene preview clip (`/scene/{id}/preview`,
    /// typically 640×360 h264). Drives the gallery long-press quick look.
    /// `nil` for sources with no server-side preview (e.g. local files).
    let previewURL: URL?
    let title: String?
    let duration: TimeInterval?

    // Stereoscopic 3D properties
    let isStereoscopic: Bool
    let stereoscopicFormat: StereoscopicFormat?
    let sourceWidth: Int?
    let sourceHeight: Int?

    /// Whether the left/right eyes are swapped in the source video (detected via "stereo_eyes_reversed" tag)
    let eyesReversed: Bool

    // Stash metadata
    var rating100: Int?
    var oCounter: Int?

    /// Original filename from server (e.g. from files path), used for sharing
    let fileName: String?

    init(
        id: UUID = UUID(),
        stashId: String,
        thumbnailURL: URL,
        streamURL: URL,
        fallbackStreamURL: URL? = nil,
        previewURL: URL? = nil,
        title: String? = nil,
        duration: TimeInterval? = nil,
        isStereoscopic: Bool = false,
        stereoscopicFormat: StereoscopicFormat? = nil,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        eyesReversed: Bool = false,
        rating100: Int? = nil,
        oCounter: Int? = nil,
        fileName: String? = nil
    ) {
        self.id = id
        self.stashId = stashId
        self.thumbnailURL = thumbnailURL
        self.streamURL = streamURL
        self.fallbackStreamURL = fallbackStreamURL
        self.previewURL = previewURL
        self.title = title
        self.duration = duration
        self.isStereoscopic = isStereoscopic
        self.stereoscopicFormat = stereoscopicFormat
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.eyesReversed = eyesReversed
        self.rating100 = rating100
        self.oCounter = oCounter
        self.fileName = fileName
    }

    /// A URL suitable for downloading the full video to disk for AVAssetReader
    /// consumption (MV-HEVC conversion, depth pre-processing). WebM sources route
    /// playback through Stash's HLS live transcode (`/stream.m3u8`) — downloading
    /// that URL yields a playlist text file, not video ("No video track found").
    /// Swap it for the server's `/stream.mp4` transcode: AVPlayer rejects that as a
    /// *stream* (non-seekable chunked pipe), but downloaded to completion it's a
    /// normal fragmented MP4 that AVAssetReader reads fine. Non-HLS sources (native
    /// MP4/MOV, or a raw WebM when the server can't transcode) return `streamURL`
    /// unchanged. Auth (apikey query param / ApiKey header) is layered by callers.
    var transcodedDownloadURL: URL {
        let hlsSuffix = "/stream.m3u8"
        guard streamURL.path.hasSuffix(hlsSuffix),
              var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)
        else { return streamURL }
        components.path = String(components.path.dropLast(hlsSuffix.count)) + "/stream.mp4"
        return components.url ?? streamURL
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
