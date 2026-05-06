/*
 Spatial Stash - Thumbnail Diorama Cache

 In-memory cache of (foreground, backdrop) pairs generated from gallery
 thumbnails for the gaze-driven Apple-TV-style parallax effect. Disk
 persistence is intentionally skipped — thumbnail-derived dioramas are
 cheap to regenerate and would conflict with the full-resolution variants
 in `BackgroundRemovalCache` (different source extents, same image URL).

 Generation runs through `BackgroundRemover` (actor) which naturally
 serializes the Vision pipeline across callers, so concurrent thumbnail
 requests queue up rather than thrashing the Neural Engine.
 */

import Foundation
import os
import UIKit

@MainActor
final class ThumbnailDioramaCache {
    static let shared = ThumbnailDioramaCache()

    final class Pair: @unchecked Sendable {
        let foreground: UIImage
        let backdrop: UIImage
        init(foreground: UIImage, backdrop: UIImage) {
            self.foreground = foreground
            self.backdrop = backdrop
        }
    }

    private let cache: NSCache<NSURL, Pair> = {
        let c = NSCache<NSURL, Pair>()
        c.totalCostLimit = 80 * 1024 * 1024 // ~80 MB of decoded thumbnail diorama bitmaps
        return c
    }()
    private var inFlight: [URL: Task<Pair?, Never>] = [:]

    private init() {}

    func cached(for url: URL) -> Pair? {
        cache.object(forKey: url as NSURL)
    }

    /// Get or generate a thumbnail diorama pair for `url`. The `source`
    /// closure is only invoked on a cache miss with no in-flight task, so
    /// callers can pass an already-loaded thumbnail UIImage cheaply.
    func dioramaPair(for url: URL, source: () -> UIImage?) async -> Pair? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let existing = inFlight[url] { return await existing.value }
        guard let sourceImage = source() else { return nil }

        let task = Task { @MainActor [weak self] () -> Pair? in
            do {
                let result = try await BackgroundRemover.shared.generateDioramaPair(from: sourceImage)
                guard let fg = result.foreground, let bg = result.backdrop else { return nil }
                let pair = Pair(foreground: fg, backdrop: bg)
                let cost = approximateByteCount(fg) + approximateByteCount(bg)
                self?.cache.setObject(pair, forKey: url as NSURL, cost: cost)
                return pair
            } catch {
                AppLogger.backgroundRemover.warning("Thumbnail diorama generation failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        inFlight[url] = task
        let result = await task.value
        inFlight.removeValue(forKey: url)
        return result
    }

    func cancel(for url: URL) {
        inFlight[url]?.cancel()
        inFlight.removeValue(forKey: url)
    }
}

private func approximateByteCount(_ image: UIImage) -> Int {
    guard let cg = image.cgImage else { return 0 }
    return cg.width * cg.height * (cg.bitsPerPixel / 8)
}
