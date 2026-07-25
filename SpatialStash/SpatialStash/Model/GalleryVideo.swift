/*
 Spatial Stash - Gallery Video Model

 Represents a video in the gallery with thumbnail and stream URLs.
 */

import Foundation

struct GalleryVideo: Identifiable, Equatable, Hashable, Codable {
    let id: UUID
    let stashId: String
    let thumbnailURL: URL
    /// Primary playback URL — always the server's *original* file (direct
    /// stream). WebKit decodes WebM (VP8/VP9) on-device, so playing the original
    /// avoids burning server CPU on a transcode nobody asked for.
    let streamURL: URL
    /// Server-side live transcode of the same scene (HLS `/stream.m3u8`
    /// preferred, else the fragmented `/stream.mp4`), when the server advertises
    /// one and Settings → Server-Side Transcoding is on. It is *not* used for
    /// playback up front; it's the escape hatch for two cases:
    /// 1. the original turns out to be undecodable (`onSourceUnplayable`), and
    /// 2. a feature needs AVFoundation — fake-3D, MV-HEVC, depth pre-process —
    ///    since those decode via AVFoundation and WebM isn't readable by it
    ///    (still true on visionOS 27: VP8 and VP9 both fail the probe).
    let transcodeStreamURL: URL?
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
        transcodeStreamURL: URL? = nil,
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
        self.transcodeStreamURL = transcodeStreamURL
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
    /// consumption (MV-HEVC conversion, depth pre-processing). Playback prefers
    /// the original file, but AVAssetReader can't read WebM at all, so this
    /// prefers the server transcode when one exists.
    ///
    /// The transcode is normally HLS (`/stream.m3u8`); downloading *that* yields
    /// a playlist text file, not video ("No video track found"), so it's
    /// rewritten to the sibling `/stream.mp4`. AVPlayer rejects that as a live
    /// *stream* (non-seekable chunked pipe), but downloaded to completion it's a
    /// normal fragmented MP4 that AVAssetReader reads fine. With no transcode
    /// available (server can't transcode, or the setting is off) this falls back
    /// to `streamURL` — fine for native MP4/MOV, and the caller surfaces a clear
    /// error for a raw WebM. Auth (apikey / ApiKey header) is layered by callers.
    var transcodedDownloadURL: URL {
        let source = transcodeStreamURL ?? streamURL
        let hlsSuffix = "/stream.m3u8"
        guard source.path.hasSuffix(hlsSuffix),
              var components = URLComponents(url: source, resolvingAgainstBaseURL: false)
        else { return source }
        components.path = String(components.path.dropLast(hlsSuffix.count)) + "/stream.mp4"
        return components.url ?? source
    }

    /// Whether a server transcode exists that AVFoundation should be able to
    /// play natively — the route to the native/Metal renderer (and hence fake-3D)
    /// for a source WebKit is currently decoding.
    var hasNativePlayableTranscode: Bool {
        transcodeStreamURL != nil
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
