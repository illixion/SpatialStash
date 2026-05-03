/*
 Spatial Stash - Shared Texture Cache

 Reference-counted GPU texture cache enabling multiple photo viewer windows
 to share the same MTLTexture when displaying the same image at the same
 resolution. Keyed by (image URL, target dimension).
 */

import Metal

@MainActor
final class SharedTextureCache {
    static let shared = SharedTextureCache()

    struct TextureKey: Hashable {
        let imageURL: String
        let maxDimension: Int
    }

    private struct CachedEntry {
        let texture: MTLTexture
        let aspectRatio: CGFloat
        var refCount: Int
    }

    private var cache: [TextureKey: CachedEntry] = [:]

    func acquire(key: TextureKey) -> (texture: MTLTexture, aspectRatio: CGFloat)? {
        guard var entry = cache[key] else { return nil }
        entry.refCount += 1
        cache[key] = entry
        return (entry.texture, entry.aspectRatio)
    }

    func store(key: TextureKey, texture: MTLTexture, aspectRatio: CGFloat) {
        cache[key] = CachedEntry(texture: texture, aspectRatio: aspectRatio, refCount: 1)
    }

    func release(key: TextureKey) {
        guard var entry = cache[key] else { return }
        entry.refCount -= 1
        if entry.refCount <= 0 {
            cache.removeValue(forKey: key)
        } else {
            cache[key] = entry
        }
    }
}
