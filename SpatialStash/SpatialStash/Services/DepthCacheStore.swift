/*
 Spatial Stash - Depth Cache Store

 Filesystem management for pre-processed fake-3D depth caches.

 A cache entry holds everything cached playback needs to warp a video at full
 frame rate without live inference: a compact HEVC grayscale video (`depth.mov`,
 depth in the luma plane, source PTS preserved) plus `meta.json` with the depth
 UV transform and per-frame display-mapping arrays computed by DepthConverter's
 lookahead post-pass.

 Entries are keyed by (video identity, depth model, pipeline version): a
 different model or an improved conversion pipeline produces different depth, so
 each gets its own entry and stale versions stop matching. Storage lives under
 Application Support (`DepthCache/`), excluded from backup like the depth
 models — large, regenerable data.
 */

import CryptoKit
import Foundation
import os

enum DepthCacheStore {
    /// Bump when the conversion pipeline changes in a way that should invalidate
    /// previously converted caches (they stop matching and can be re-converted;
    /// stale entries remain listed in Settings for manual cleanup).
    static let pipelineVersion = 1

    static let depthVideoFilename = "depth.mov"
    static let metaFilename = "meta.json"

    /// Everything cached playback needs, written by DepthConverter at the end of
    /// a successful conversion. Per-frame arrays are indexed by frame and mapped
    /// at playback via binary search on `framePTS`.
    struct Meta: Codable {
        let version: Int
        let videoIdentity: String
        let modelName: String
        let title: String?
        /// Decoded dimensions used for inference (same aspect as the source).
        let sourceWidth: Int
        let sourceHeight: Int
        let depthWidth: Int
        let depthHeight: Int
        /// Letterbox UV transform (frame UV → depth content region), matching
        /// CoreMLDepthProvider.letterboxUVTransform for the dims above.
        let uvScaleX: Float
        let uvScaleY: Float
        let uvOffsetX: Float
        let uvOffsetY: Float
        let frameCount: Int
        let duration: Double
        let completed: Bool
        let createdAt: Date
        /// Per-frame presentation timestamps (seconds), ascending.
        let framePTS: [Double]
        /// Per-frame affine mapping from the stored luma value v (0-1) to the
        /// display-normalized depth the warp consumes: d = v*scale + bias. Bakes
        /// the frame's own encode range together with the lookahead-smoothed
        /// display range, so playback needs no further stats work.
        let displayScale: [Float]
        let displayBias: [Float]
        /// Per-frame median depth in display space (0-1), lookahead-smoothed —
        /// drives auto-convergence.
        let displayMedian: [Float]
    }

    struct Entry {
        let directory: URL
        let meta: Meta
        var depthVideoURL: URL { directory.appendingPathComponent(DepthCacheStore.depthVideoFilename) }
    }

    // MARK: Directories & keys

    /// `Application Support/DepthCache`, created on first use, excluded from
    /// backup (large, regenerable).
    static var cacheDirectory: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("DepthCache", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var mutable = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutable.setResourceValues(values)
        }
        return dir
    }

    /// Filesystem-safe entry folder name. The identity is hashed (it may be a
    /// URL or path); the model name and version stay readable for debugging.
    static func entryKey(videoIdentity: String, modelName: String) -> String {
        let digest = SHA256.hash(data: Data(videoIdentity.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        let safeModel = modelName.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "\(hash)_\(String(safeModel))_v\(pipelineVersion)"
    }

    static func entryDirectory(videoIdentity: String, modelName: String) -> URL {
        cacheDirectory.appendingPathComponent(entryKey(videoIdentity: videoIdentity, modelName: modelName), isDirectory: true)
    }

    // MARK: Query

    /// The completed cache entry for (video, model) at the current pipeline
    /// version, or nil. Incomplete/partial conversions never match.
    static func entry(videoIdentity: String, modelName: String) -> Entry? {
        let dir = entryDirectory(videoIdentity: videoIdentity, modelName: modelName)
        guard let meta = readMeta(in: dir),
              meta.completed,
              meta.version == pipelineVersion,
              FileManager.default.fileExists(atPath: dir.appendingPathComponent(depthVideoFilename).path)
        else { return nil }
        return Entry(directory: dir, meta: meta)
    }

    /// The completed entry for a video regardless of which model produced it:
    /// the currently selected model's entry when present, else any completed
    /// current-version entry. Converted depth outlives model deletion — the
    /// depth is baked, so playback doesn't need the model anymore.
    static func entry(videoIdentity: String) -> Entry? {
        if let model = CoreMLDepthProvider.resolvedModelName(),
           let preferred = entry(videoIdentity: videoIdentity, modelName: model) {
            return preferred
        }
        return allEntries().first {
            $0.meta.completed
                && $0.meta.version == pipelineVersion
                && $0.meta.videoIdentity == videoIdentity
                && FileManager.default.fileExists(atPath: $0.depthVideoURL.path)
        }
    }

    /// All entries with readable metadata (any version, including stale ones),
    /// for the Settings management list.
    static func allEntries() -> [Entry] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return dirs.compactMap { dir in
            readMeta(in: dir).map { Entry(directory: dir, meta: $0) }
        }
        .sorted { $0.meta.createdAt > $1.meta.createdAt }
    }

    static func entrySize(_ entry: Entry) -> Int64 {
        directorySize(entry.directory)
    }

    static func totalSize() -> Int64 {
        directorySize(cacheDirectory)
    }

    // MARK: Mutate

    static func writeMeta(_ meta: Meta, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meta)
        try data.write(to: directory.appendingPathComponent(metaFilename), options: .atomic)
    }

    static func deleteEntry(at directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        AppLogger.videoCache.info("Deleted depth cache entry: \(directory.lastPathComponent, privacy: .public)")
    }

    static func deleteAll() {
        let fm = FileManager.default
        try? fm.removeItem(at: cacheDirectory)
        AppLogger.videoCache.notice("Cleared depth cache")
    }

    // MARK: Private

    private static func readMeta(in directory: URL) -> Meta? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(metaFilename)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Meta.self, from: data)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
