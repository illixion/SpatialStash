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
    /// v2: joint-bilateral widened (σ 2.5→5, r 5→12) to suppress the DINOv2
    /// patch-grid "wavy glass" ripple on low-texture content.
    /// v3: depth encoded at 2× model resolution via guided joint-bilateral
    /// upsample (silhouette stairstepping — the 1× depth texel lattice
    /// quantized the warped edge position; see encodeUpsampleFactor).
    /// v4: temporal window gated by depth similarity to the center frame
    /// (moving silhouettes shimmered — the uncompensated ±2 average painted
    /// scrolling ghost bands the sharp v3 encode made visible).
    static let pipelineVersion = 4

    static let depthVideoFilename = "depth.mov"
    /// Two-pass (high-frame-rate) conversions write the second pass's frames
    /// (the odd half of the lattice) here — a finished AVAssetWriter file
    /// can't accept interleaved PTS. DepthCacheReader merges both files by
    /// PTS; single-pass entries simply have no secondary file.
    static let secondaryDepthVideoFilename = "depth-b.mov"
    static let metaFilename = "meta.json"
    static let progressFilename = "progress.json"

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
        /// Per-frame median depth in display space (0-1), lookahead-smoothed.
        /// Vestigial: it drove auto-convergence, which was removed once
        /// convergence 1.0 proved to work across content (the realtime map is
        /// normalized per frame, so a fixed 1.0 already pins each frame's
        /// nearest content to the window plane — and unlike a tracked median it
        /// can't wander). Still written, and still required here, because the
        /// converter computes it as a by-product of the histogram it needs for
        /// p2/p98 anyway: dropping it would change the converter's output and
        /// force a `pipelineVersion` bump, invalidating every existing cache
        /// entry for no benefit.
        let displayMedian: [Float]
    }

    /// Small, frequently rewritten progressive-playback signal. Keeping this
    /// separate avoids re-encoding the large per-frame metadata arrays merely
    /// to advertise that another video fragment became readable.
    struct Progress: Codable {
        let primaryFrontier: Double
        let secondaryFrontier: Double?
    }

    struct Entry {
        let directory: URL
        let meta: Meta
        var depthVideoURL: URL { directory.appendingPathComponent(DepthCacheStore.depthVideoFilename) }
        var secondaryDepthVideoURL: URL { directory.appendingPathComponent(DepthCacheStore.secondaryDepthVideoFilename) }
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
        if let model = CoreMLDepthProvider.resolvedModelName(role: .preprocess),
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

    /// The entry the *engage flow* accepts as "already converted": strictly the
    /// selected pre-process model's entry while a model is installed — so
    /// switching the pre-process model offers a fresh conversion instead of
    /// silently reusing another model's baked depth. Only with no installed
    /// model (nothing to convert with) does it fall back to any completed
    /// entry, keeping old conversions playable after model deletion. Playback
    /// lookups stay on the lenient `entry(videoIdentity:)`.
    static func engageEntry(videoIdentity: String) -> Entry? {
        if let model = CoreMLDepthProvider.resolvedModelName(role: .preprocess) {
            return entry(videoIdentity: videoIdentity, modelName: model)
        }
        return entry(videoIdentity: videoIdentity)
    }

    /// The still-growing (incomplete) entry for a video — progressive playback
    /// while DepthConversionManager is converting it. Callers must ensure a
    /// conversion is actually running: an *abandoned* partial entry would play
    /// flat past its last written fragment. Never returned by `entry()`.
    static func inProgressEntry(videoIdentity: String) -> Entry? {
        allEntries().first {
            $0.meta.version == pipelineVersion
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

    // MARK: Budget

    /// Stamp an entry as recently used. DepthCacheReader calls this when
    /// playback opens an entry, so `enforceBudget` evicts least-recently-
    /// watched conversions first.
    static func touch(_ entry: Entry) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: entry.directory.path
        )
    }

    /// LRU-evict completed entries when the depth cache exceeds its
    /// CacheBudget share. Depth conversions are expensive to regenerate, so
    /// unlike the Caches-directory caches this lives in Application Support
    /// (never purged by the OS) and only this trims it. In-progress entries
    /// and `activeIdentity` (converting or just completed) are never evicted.
    static func enforceBudget(activeIdentity: String? = nil) {
        var total = totalSize()
        let cap = CacheBudget.cap(for: .depth, currentSize: total)
        guard total > cap else { return }

        let target = Int64(Double(cap) * 0.8)
        let candidates = allEntries()
            .filter { $0.meta.completed && $0.meta.videoIdentity != activeIdentity }
            .map { entry -> (entry: Entry, date: Date) in
                let date = (try? entry.directory.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? entry.meta.createdAt
                return (entry, date)
            }
            .sorted { $0.date < $1.date }

        for (entry, _) in candidates {
            guard total > target else { break }
            let size = entrySize(entry)
            deleteEntry(at: entry.directory)
            total -= size
            AppLogger.videoCache.notice("Depth cache over budget: evicted \(entry.meta.title ?? entry.meta.videoIdentity, privacy: .private)")
        }
    }

    // MARK: Mutate

    static func writeMeta(_ meta: Meta, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meta)
        try data.write(to: directory.appendingPathComponent(metaFilename), options: .atomic)
    }

    static func writeProgress(_ progress: Progress, to directory: URL) throws {
        let data = try JSONEncoder().encode(progress)
        try data.write(to: directory.appendingPathComponent(progressFilename), options: .atomic)
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

    /// Internal (not private): DepthCacheReader re-reads metadata while a
    /// progressive entry grows.
    static func readMeta(in directory: URL) -> Meta? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(metaFilename)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Meta.self, from: data)
    }

    static func readProgress(in directory: URL) -> Progress? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(progressFilename)) else {
            return nil
        }
        return try? JSONDecoder().decode(Progress.self, from: data)
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
