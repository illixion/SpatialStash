/*
 Hypnos - Photos Index Schema

 The shape of the local mirror of the photo library, and the row types that
 cross the store's actor boundary.

 One rule governs everything here, and it is what keeps the index from becoming
 a second source of truth: **the index decides which assets and in what order;
 PhotoKit remains the only thing that produces pixels.** Queries return
 identifiers and the cheap metadata a grid cell needs to lay itself out. A row
 that has gone stale therefore yields an asset that fails to resolve and drops
 out at load time — the same failure the old fetch-snapshot path already had,
 not a new class of bug.

 No foreign keys, deliberately. An album can contain an asset this index skips
 (audio, or a type we do not browse), and `INSERT OR IGNORE` does not extend to
 foreign-key violations — so declaring them would turn an ordinary library into
 a failed build. Membership rows are cleaned up explicitly on delete instead.

 Bumping `version` drops and rebuilds. That is the whole migration story, and it
 is available precisely because nothing here is authoritative.
 */

import Foundation
import Photos

enum PhotosIndexSchema {

    /// Bump to invalidate every existing index. Rebuild is the only migration.
    static let version = 1

    static let statements = """
    CREATE TABLE IF NOT EXISTS asset (
        id              TEXT PRIMARY KEY,
        kind            INTEGER NOT NULL,
        subtypes        INTEGER NOT NULL,
        favorite        INTEGER NOT NULL,
        created         REAL,
        modified        REAL,
        width           INTEGER NOT NULL,
        height          INTEGER NOT NULL,
        duration        REAL NOT NULL,
        filename        TEXT,
        filename_folded TEXT,
        random_rank     INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS asset_kind_created  ON asset(kind, created DESC);
    CREATE INDEX IF NOT EXISTS asset_kind_modified ON asset(kind, modified DESC);
    CREATE INDEX IF NOT EXISTS asset_kind_random   ON asset(kind, random_rank);
    CREATE INDEX IF NOT EXISTS asset_kind_name     ON asset(kind, filename_folded);
    CREATE INDEX IF NOT EXISTS asset_unnamed       ON asset(id) WHERE filename IS NULL;

    CREATE TABLE IF NOT EXISTS album (
        id          TEXT PRIMARY KEY,
        title       TEXT NOT NULL,
        is_smart    INTEGER NOT NULL,
        sort_order  INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS album_asset (
        album_id TEXT NOT NULL,
        asset_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        PRIMARY KEY (album_id, asset_id)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS album_asset_by_asset ON album_asset(asset_id);

    CREATE TABLE IF NOT EXISTS person (
        id           TEXT PRIMARY KEY,
        name         TEXT NOT NULL,
        key_asset_id TEXT,
        sort_order   INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS person_asset (
        person_id TEXT NOT NULL,
        asset_id  TEXT NOT NULL,
        PRIMARY KEY (person_id, asset_id)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS person_asset_by_asset ON person_asset(asset_id);

    CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value BLOB
    );
    """

    enum MetaKey {
        static let schemaVersion = "schemaVersion"
        /// Archived `PHPersistentChangeToken`, the resume point for incremental sync.
        static let changeToken = "changeToken"
        /// The authorization the index was built under. A `.limited` index is a
        /// subset, and must not go on posing as a complete library once the user
        /// widens the grant.
        static let authScope = "authScope"
        /// Set once the cheap pass has covered the whole library, so a partial
        /// first build is never mistaken for a complete one.
        static let assetPassComplete = "assetPassComplete"
    }
}

// MARK: - Row types

/// Everything about an asset the index stores, gathered without any per-asset
/// XPC. Filenames are the exception and arrive later; see `PhotosIndexer`.
struct PhotosIndexAssetRow: Sendable {
    let id: String
    let kind: Int
    let subtypes: Int
    let favorite: Bool
    let created: Date?
    let modified: Date?
    let width: Int
    let height: Int
    let duration: Double

    init(asset: PHAsset) {
        id = asset.localIdentifier
        kind = asset.mediaType.rawValue
        subtypes = Int(asset.mediaSubtypes.rawValue)
        favorite = asset.isFavorite
        created = asset.creationDate
        modified = asset.modificationDate
        width = asset.pixelWidth
        height = asset.pixelHeight
        duration = asset.duration
    }
}

/// A row as the gallery reads it back.
struct PhotosIndexedAsset: Sendable {
    let id: String
    let filename: String?
    let width: Int
    let height: Int
    let duration: Double
}

struct PhotosIndexAlbumRow: Sendable {
    let id: String
    let title: String
    let isSmart: Bool
    let sortOrder: Int
    let assetIds: [String]
}

/// A person the index knows about, with a representative asset so a filter chip
/// can show a face rather than a name alone.
struct IndexedPerson: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Local identifier of the asset to draw the chip's thumbnail from.
    let keyAssetId: String?
    let count: Int
}
