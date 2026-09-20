import Foundation

/// One media file as a search returns it.
///
/// Deliberately flat and free of any app's gallery model: callers adapt this
/// into whatever their grid wants. Everything here comes back in the same
/// single SEARCH response, so building one of these costs no extra request.
public struct NextcloudItem: Sendable, Equatable, Identifiable {
    /// Nextcloud's numeric file id. Stable across renames and moves, which is
    /// why it — not the path — is the identity and the preview key.
    public let fileID: Int
    /// Path relative to the user's files root, e.g. `Photos/2026/03/IMG_1.HEIC`.
    public let path: String
    /// Fully qualified URL to download the original.
    public let downloadURL: URL
    public let contentType: String
    public let contentLength: Int64
    /// Server ETag, without the quotes DAV wraps it in. Suitable as a cache key.
    public let etag: String
    /// File mtime. Whether this is the capture date depends on how the library
    /// was populated — an `osxphotos --touch-file` export makes it so, an
    /// ordinary upload does not.
    public let lastModified: Date?
    /// Whether the server already holds a rendered preview. `false` means the
    /// preview endpoint will either generate on demand (slow) or 404.
    public let hasPreview: Bool
    /// Pixel dimensions, when the server has extracted them. Frequently absent:
    /// the photo metadata is populated by a background job that bulk-scanned
    /// libraries never ran, so a grid must cope without it.
    public let pixelSize: PixelSize?
    /// EXIF capture time, when extracted. Absent for the same reason as `pixelSize`.
    public let captureDate: Date?
    /// BlurHash for a progressive placeholder, when extracted.
    public let blurHash: String?

    public var id: Int { fileID }

    /// Last path component, percent-decoded.
    public var filename: String {
        (path as NSString).lastPathComponent
    }

    public var isVideo: Bool { contentType.hasPrefix("video/") }
    public var isImage: Bool { contentType.hasPrefix("image/") }

    public struct PixelSize: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
        public var aspectRatio: Double {
            height == 0 ? 1 : Double(width) / Double(height)
        }
    }

    public init(fileID: Int, path: String, downloadURL: URL, contentType: String,
                contentLength: Int64, etag: String, lastModified: Date?,
                hasPreview: Bool, pixelSize: PixelSize?, captureDate: Date?,
                blurHash: String?) {
        self.fileID = fileID
        self.path = path
        self.downloadURL = downloadURL
        self.contentType = contentType
        self.contentLength = contentLength
        self.etag = etag
        self.lastModified = lastModified
        self.hasPreview = hasPreview
        self.pixelSize = pixelSize
        self.captureDate = captureDate
        self.blurHash = blurHash
    }
}

/// What a page of results asks for.
public struct NextcloudQuery: Sendable, Equatable {
    /// Which media to return.
    public enum Kind: Sendable, Equatable {
        case images
        case videos
        case both

        /// The `getcontenttype` patterns this kind matches.
        var mimePatterns: [String] {
            switch self {
            case .images: return ["image/%"]
            case .videos: return ["video/%"]
            case .both: return ["image/%", "video/%"]
            }
        }
    }

    public enum SortField: Sendable, Equatable {
        case lastModified
        case path
        case size

        var davProperty: String {
            switch self {
            case .lastModified: return "getlastmodified"
            case .path: return "displayname"
            case .size: return "getcontentlength"
            }
        }
    }

    public var kind: Kind
    public var sortField: SortField
    public var descending: Bool
    /// 0-indexed offset. Nextcloud resolves this in SQL, so a deep offset costs
    /// the same as a shallow one (measured flat at offset 10,000).
    public var offset: Int
    public var limit: Int
    /// Substring match on the filename. Empty means no filter.
    public var searchTerm: String

    public init(kind: Kind = .images,
                sortField: SortField = .lastModified,
                descending: Bool = true,
                offset: Int = 0,
                limit: Int = 100,
                searchTerm: String = "") {
        self.kind = kind
        self.sortField = sortField
        self.descending = descending
        self.offset = offset
        self.limit = limit
        self.searchTerm = searchTerm
    }
}

/// A page of results plus enough to decide whether to ask for another.
public struct NextcloudPage: Sendable, Equatable {
    public let items: [NextcloudItem]
    /// Whether a further page is likely to exist.
    ///
    /// DAV SEARCH reports no total, so this is inferred: a short page means the
    /// end. A page that is exactly `limit` long may or may not be the last one,
    /// and answering `true` costs at most one empty request — answering `false`
    /// would silently truncate the library.
    public let hasMore: Bool

    public init(items: [NextcloudItem], hasMore: Bool) {
        self.items = items
        self.hasMore = hasMore
    }
}
