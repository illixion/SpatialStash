/*
 Spatial Stash - Library Source

 Which library the Pictures and Videos tabs are browsing.

 Distinct from `MediaSource`, which records where an individual item came from.
 This is the app-level choice of what to show, and it exists because the two
 were previously conflated: the source was inferred from whether
 `stashServerURL` happened to be non-empty, which made a configured server
 silently suppress the photo library altogether. There was no way to look at
 your own photos without clearing the server setting.
 */

import Foundation

enum LibrarySource: String, Codable, CaseIterable, Sendable {
    /// The device photo library.
    case photos
    /// A Stash server.
    case stash
    /// Files placed in the app's own Documents folder.
    case local

    var symbolName: String {
        switch self {
        case .photos: return "photo.artframe"
        case .stash:  return "archivebox"
        // Matches the Files app's icon for "On My Apple Vision Pro" — the
        // same on-device-storage idea this source is.
        case .local:  return "vision.pro"
        }
    }

    var displayName: String {
        switch self {
        case .photos: return "Photos"
        case .stash:  return "Stash"
        case .local:  return "Local Files"
        }
    }
}
