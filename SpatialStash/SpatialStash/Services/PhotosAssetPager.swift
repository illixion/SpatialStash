/*
 Spatial Stash - Photos Asset Pager

 The paging half of both Photos sources.

 `PhotosImageSource` and `PhotosVideoSource` began as copies of each other and
 differed only in the media type and in how a `PHAsset` was mapped to a gallery
 item. Everything else — the fetch snapshot and the reason for it, the page
 arithmetic, the authorization guard, the shuffle — was the same code twice, so
 it lives here once and each source keeps only its mapping.

 Two behaviours worth knowing about:

 **The fetch result is snapshotted**, not re-fetched per page. Paging over a
 live `PHFetchResult` would let an import or a deletion shift every index
 mid-scroll, so the user would see photos duplicated or skipped with no way to
 tell why. A snapshot can go stale instead, which is the better failure: a
 deleted asset simply stops resolving and drops out at load time. The snapshot
 is invalidated by any change to the criteria, which is why the whole criteria
 value is the cache key — including `randomSeed`, so a shuffle re-permutes.

 **Random is a permutation, not a sort.** PhotoKit cannot sort randomly, so the
 fetch is ordered by date and a seeded shuffle of the indices is laid over it.
 Seeded, because pagination has to agree with itself: an unseeded shuffle would
 redraw the order on every page and show the same photo repeatedly.
 */

import Foundation
import Photos

final class PhotosAssetPager: @unchecked Sendable {

    struct Page {
        let assets: [PHAsset]
        let total: Int
        let hasMore: Bool

        static let empty = Page(assets: [], total: 0, hasMore: false)
    }

    private let mediaType: PHAssetMediaType
    private let lock = NSLock()

    /// The criteria the current snapshot was taken for, nil if none has been.
    private var snapshotCriteria: PhotosFilterCriteria?
    private var snapshot: PHFetchResult<PHAsset>?
    /// Index permutation, non-nil only when sorting randomly.
    private var order: [Int]?

    init(mediaType: PHAssetMediaType) {
        self.mediaType = mediaType
    }

    func page(_ page: Int, pageSize: Int, criteria: PhotosFilterCriteria) -> Page {
        // Not having been asked for permission yet is not an error, and the
        // gallery explains the authorization state itself, so an unreadable
        // library is an empty page rather than a thrown "no images available".
        guard PhotosAuthorization.isReadable else { return .empty }

        let criteria = criteria.normalized(for: mediaType)
        let (assets, order) = resolveSnapshot(for: criteria)
        let total = assets.count
        let start = page * pageSize
        guard start < total else {
            return Page(assets: [], total: total, hasMore: false)
        }
        let end = min(start + pageSize, total)

        var result: [PHAsset] = []
        result.reserveCapacity(end - start)
        for position in start..<end {
            let index = order.map { $0[position] } ?? position
            result.append(assets.object(at: index))
        }
        return Page(assets: result, total: total, hasMore: end < total)
    }

    // MARK: - Snapshot

    private func resolveSnapshot(for criteria: PhotosFilterCriteria) -> (PHFetchResult<PHAsset>, [Int]?) {
        lock.lock()
        defer { lock.unlock() }

        if let snapshot, snapshotCriteria == criteria {
            return (snapshot, order)
        }

        let options = criteria.fetchOptions(for: mediaType)
        let result: PHFetchResult<PHAsset>
        if let collection = criteria.resolvedCollection() {
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }

        snapshot = result
        snapshotCriteria = criteria
        order = criteria.sortField == .random
            ? Self.shuffledIndices(count: result.count, seed: criteria.randomSeed ?? 1)
            : nil
        return (result, order)
    }

    // MARK: - Shuffle

    /// A Fisher-Yates shuffle driven by SplitMix64, so the same seed always
    /// produces the same order — on this launch and the next.
    private static func shuffledIndices(count: Int, seed: Int) -> [Int] {
        var indices = Array(0..<count)
        guard count > 1 else { return indices }
        var state = UInt64(bitPattern: Int64(seed)) &+ 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        for i in stride(from: count - 1, to: 0, by: -1) {
            let j = Int(next() % UInt64(i + 1))
            indices.swapAt(i, j)
        }
        return indices
    }
}
