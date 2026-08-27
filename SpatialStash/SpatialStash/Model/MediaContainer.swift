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
        /// A Stash gallery, which holds images.
        case gallery
        /// A Stash group, which holds scenes — the counterpart to a gallery.
        case group

        var symbolName: String {
            switch self {
            case .album: return "rectangle.stack"
            case .smartAlbum: return "wand.and.stars"
            case .gallery: return "photo.on.rectangle.angled"
            case .group: return "film.stack"
            }
        }

        /// Whether to present this after, and more quietly than, the rest.
        /// Smart albums are the system's, not the user's.
        var isSecondary: Bool {
            self == .smartAlbum
        }

        /// What to call a collection of these, in the user's words.
        var pluralTitle: String {
            switch self {
            case .album, .smartAlbum: return "Albums"
            case .gallery: return "Galleries"
            case .group: return "Groups"
            }
        }

        /// The kind a library uses to hold one media kind.
        ///
        /// Both the browser and the grid's banner need to name the thing being
        /// browsed, and each deriving it was two places to forget that Stash
        /// calls the video one a group.
        static func inLibrary(_ source: LibrarySource, isVideo: Bool) -> Kind {
            switch source {
            case .photos: return .album
            case .stash:  return isVideo ? .group : .gallery
            }
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

// MARK: - Mapping

/*
 One conversion per library type, because there are two callers for each — the
 Albums browser and the Filters tab's option list — and having them each map the
 fields is precisely how two views end up disagreeing about what an empty count
 or a missing cover means.
 */
extension MediaContainer {
    init(album: PhotoAlbum) {
        self.init(id: album.id,
                  name: album.name,
                  count: album.count,
                  kind: album.isSmart ? .smartAlbum : .album,
                  // The album's first asset of the filtered media type,
                  // addressed the same way any other asset is.
                  coverURL: album.keyAssetId.flatMap(PhotosAssetURL.url(forLocalIdentifier:)))
    }

    init(gallery: StashAPIClient.StashGallery) {
        self.init(id: gallery.id,
                  name: gallery.displayName,
                  count: gallery.image_count ?? 0,
                  kind: .gallery,
                  coverURL: gallery.cover?.paths?.thumbnail.flatMap(URL.init(string:)))
    }

    init(group: StashAPIClient.StashGroup) {
        self.init(id: group.id,
                  name: group.name,
                  count: group.scene_count ?? 0,
                  kind: .group,
                  coverURL: group.front_image_path.flatMap(URL.init(string:)))
    }

    /// As a filter-list option.
    var filterOption: FilterOption {
        FilterOption(id: id,
                     name: name,
                     detail: "\(count)",
                     thumbnailURL: coverURL,
                     isSecondary: kind.isSecondary)
    }
}
