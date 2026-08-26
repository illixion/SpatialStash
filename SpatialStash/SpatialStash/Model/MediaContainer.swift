/*
 Spatial Stash - Media Container

 One browsable grouping of media, whatever the library calls it: a Photos album,
 a Photos smart album, or a Stash gallery.

 The point of the shared model is that the Albums tab is a *browser*, not a
 second content pipeline. Opening a container applies it as a filter and sends
 you to the Pictures or Videos grid, so it reuses the whole existing path —
 index query or GraphQL, paging, sort, multi-select — and adds no parallel way to
 list media. In this architecture a container genuinely is a filter; the browser
 is a nicer way to reach one than a picker in the Filters tab.

 Covers are a single URL rather than a per-library pair because
 `ImageLoader.loadThumbnail(from:)` already resolves all the shapes involved: a
 `photos-asset:///` URL, a local file, or a server thumbnail. Splitting the field
 by source would have added a branch to describe a difference that does not
 survive contact with the loader.

 Local folders are deliberately not here yet. They are the third case the plan
 calls for, but nothing produces one until the Local tab is folded in, and a case
 no code path can construct is a liability rather than a head start.
 */

import Foundation

struct MediaContainer: Identifiable, Hashable, Sendable {

    enum Kind: Sendable {
        /// An album the user made.
        case album
        /// A system smart album — Favourites, Spatial, Recently Added.
        case smartAlbum
        /// A Stash gallery.
        case gallery

        var symbolName: String {
            switch self {
            case .album: return "rectangle.stack"
            case .smartAlbum: return "wand.and.stars"
            case .gallery: return "photo.on.rectangle.angled"
            }
        }

        /// Whether to present this after, and more quietly than, the rest.
        /// Smart albums are the system's, not the user's.
        var isSecondary: Bool {
            self == .smartAlbum
        }
    }

    /// The library's own identifier: a `PHAssetCollection.localIdentifier` or a
    /// Stash gallery id. Used verbatim as the filter value.
    let id: String
    let name: String
    let count: Int
    let kind: Kind
    /// Anything `ImageLoader.loadThumbnail(from:)` can resolve, or nil.
    let coverURL: URL?

    /// As a filter value.
    var filterItem: AutocompleteItem {
        AutocompleteItem(id: id, name: name)
    }
}
