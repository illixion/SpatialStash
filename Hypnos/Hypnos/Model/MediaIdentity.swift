/*
 Hypnos - Media Identity

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

import CryptoKit
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

    /// Rebuilds a stale container file URL against the current container.
    ///
    /// The counterpart to `persistentKey(for:)`, and deliberately sharing its
    /// `containerRoots`: two ad hoc copies of this logic previously looked for
    /// `Documents` alone, so share-sheet media — which `SharedMediaCache`
    /// stores under `Library/Caches/SharedMedia/` precisely so it survives for
    /// window restoration — could never be repaired. A restored window opened
    /// on a dead path instead.
    ///
    /// Returns `url` unchanged when it still resolves, the rebuilt URL when the
    /// file is found under the current container, and `nil` when neither holds
    /// (the file is genuinely gone, or lives outside the container).
    static func resolvingContainerURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let parts = url.pathComponents

        // Try every component that names a container root, deepest first, and
        // accept the first rebuild that actually exists. Picking one index up
        // front cannot be done safely: a user folder legitimately named
        // "Library" or "tmp" inside Documents makes the deepest match the wrong
        // root, and a plain "Documents" match is wrong for share-sheet media
        // under Library/Caches. Verifying instead of guessing settles it, and
        // path component counts are small enough that the loop is free.
        for rootIndex in parts.indices.reversed() where containerRoots.contains(parts[rootIndex]) {
            guard let base = currentContainerRoot(named: parts[rootIndex]) else { continue }
            var rebuilt = base
            // `base` already IS the root directory, so rebuild from the
            // component after it — unlike persistentKey, which keeps the root
            // in the key it returns.
            for part in parts[(rootIndex + 1)...] {
                rebuilt = rebuilt.appendingPathComponent(part)
            }
            if FileManager.default.fileExists(atPath: rebuilt.path) { return rebuilt }
        }
        return nil
    }

    /// This launch's URL for one of the `containerRoots` directories.
    private static func currentContainerRoot(named name: String) -> URL? {
        let fm = FileManager.default
        switch name {
        case "Documents": return fm.urls(for: .documentDirectory, in: .userDomainMask).first
        case "Library":   return fm.urls(for: .libraryDirectory, in: .userDomainMask).first
        case "tmp":       return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        default:          return nil
        }
    }

    /// Whether `value` is plausibly a Stash scene or image id.
    ///
    /// Stash ids are bare decimal strings. Everything else this app mints as an
    /// identity is distinguishable on sight: `file-relative:…`, `stream:…`, a
    /// `file://` URL, or (in archives written before identity was split out) an
    /// absolute http(s) URL. That makes this a reliable way to decide whether a
    /// legacy archive's `stashId` was a real Stash id or just an identity
    /// wearing the field.
    /// A UUID derived deterministically from an identity string.
    ///
    /// Gallery items used to mint a fresh `UUID()` per instance, which made
    /// `Identifiable` conformance meaningless across reloads: re-fetching the
    /// same page produced all-new ids, so SwiftUI tore down and rebuilt every
    /// cell and every thumbnail reloaded. A visible flicker, on every filter
    /// change and every gallery refresh.
    ///
    /// Deriving it from the identity means the same asset is the same view
    /// across reloads, so cells are reused and the reload is invisible. It also
    /// makes a restored window's item id match the live gallery's.
    ///
    /// The first 16 bytes of SHA-256 — a hash, not RFC 4122 — because nothing
    /// here parses the UUID, it only compares them.
    static func stableID(for identity: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
        // Stamp version 4 / variant bits so the value is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func isStashID(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isNumber)
    }
}
