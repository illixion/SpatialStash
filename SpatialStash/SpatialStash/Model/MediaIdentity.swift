/*
 Spatial Stash - Media Identity

 Stable, launch-independent keys for a piece of media.

 Everything that persists per-item state keys off one of these: the pseudo-3D
 depth cache (`DepthCacheStore.videoIdentity`), the enhancement tracker's
 remembered viewing mode / flip / resolution / window size / adjustments, and
 the per-window registries in `AppModel`.

 The subtlety this type exists for: on visionOS the app sandbox container UUID
 changes on every launch, so a `file://` URL's `absoluteString` is a different
 string each run. Using it as a persistent key silently orphans every stored
 entry for local media at each launch — the state is written, never read again,
 and the dictionary grows forever. `persistentKey(for:)` collapses a container
 file URL to its container-relative path, which is stable, while leaving remote
 URLs (Stash, streams) exactly as they were so keys written before this type
 existed still resolve.
 */

import Foundation

/// Where a piece of media came from.
///
/// Replaces the stringly-typed `GalleryImage.source`, whose only two values
/// were compared by literal at each call site. The raw values match the old
/// strings so archives written before this type existed still decode.
enum MediaSource: String, Codable, Sendable {
    /// A Stash server scene or image.
    case stash
    /// A file browsed from the app's Documents folder.
    case local
    /// A `PHAsset` from the device photo library.
    case photos
    /// A file handed in through the share sheet and copied to the share cache.
    case shared

    /// Whether this source's URLs point inside the app container, and so go
    /// stale whenever visionOS reassigns the container UUID at launch.
    ///
    /// Share-sheet media counts. It previously defaulted to `.stash` and was
    /// therefore skipped by URL re-resolution despite living in the container —
    /// while deliberately *not* counting as `.local`, which would have handed it
    /// LocalImageSource folder navigation it has no business having.
    var isContainerFile: Bool {
        self == .local || self == .shared
    }
}

enum MediaIdentity {

    /// Directory names inside the app container whose subpath is stable across
    /// launches even though the container UUID above them is not.
    private static let containerRoots = ["Documents", "Library", "tmp"]

    /// A stable key for `url`, suitable for persisting.
    ///
    /// Remote URLs are returned verbatim — they are already stable, and
    /// preserving them keeps every key written before this function existed
    /// (Stash images and scenes, `stream:` sources) resolvable.
    ///
    /// Container file URLs collapse to `file-relative:<root>/<subpath>`, e.g.
    /// `file-relative:Documents/Photos/holiday.heic`. Non-container file URLs
    /// (an external volume, a security-scoped bookmark target) keep their
    /// absolute path, which is the best available answer for them.
    static func persistentKey(for url: URL) -> String {
        guard url.isFileURL else { return url.absoluteString }

        let parts = url.pathComponents
        // Take the LAST occurrence: a file legitimately named "Documents"
        // deeper in the tree must not be mistaken for the container root.
        guard let rootIndex = parts.lastIndex(where: { containerRoots.contains($0) }),
              rootIndex + 1 < parts.count else {
            return url.absoluteString
        }

        let relative = parts[rootIndex...].joined(separator: "/")
        return "file-relative:\(relative)"
    }

    /// True when `key` was produced from a container file URL by
    /// `persistentKey(for:)` — i.e. it is one of the stable relative forms
    /// rather than a raw absolute URL.
    static func isRelativeFileKey(_ key: String) -> Bool {
        key.hasPrefix("file-relative:")
    }

    /// Whether `value` is plausibly a Stash scene or image id.
    ///
    /// Stash ids are bare decimal strings. Everything else this app mints as an
    /// identity is distinguishable on sight: `file-relative:…`, `stream:…`, a
    /// `file://` URL, or (in archives written before identity was split out) an
    /// absolute http(s) URL. That makes this a reliable way to decide whether a
    /// legacy archive's `stashId` was a real Stash id or just an identity
    /// wearing the field.
    static func isStashID(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isNumber)
    }
}
