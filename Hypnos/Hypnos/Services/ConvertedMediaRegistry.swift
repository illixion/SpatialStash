/*
 Hypnos - Converted Media Registry

 Answers "which items has this app already produced 3D output for", across both
 libraries, for the Converted to 3D filter.

 Nothing new is stored. The two places that already know are asked directly:

   * Videos — `DepthCacheStore`, whose completed entries each carry the
     `videoIdentity` they were converted from. A cache entry *is* the conversion,
     so this cannot drift.
   * Images — `ImageEnhancementTracker`, which records the identity alongside the
     URL at the moment a spatial 3D conversion succeeds.

 Mirroring either of them into the photo index was the alternative and would have
 been wrong twice over: the index is dropped when photo access is revoked and
 rebuilt on a schema bump, and neither should cost you the record of what you
 have converted — including for Stash, which the index does not cover at all.

 Identities are then sorted by shape rather than by a stored kind: a Photos asset
 identity is a `photos-asset:///` URL, and a Stash identity is the bare scene or
 image id. That test lives in `MediaIdentity` and `PhotosAssetURL`, so this file
 adds no new notion of what an identity looks like.
 */

import Foundation
import RAVEMedia

enum ConvertedMediaRegistry {

    /// Every identity with 3D output, for one media kind.
    static func convertedIdentities(isVideo: Bool) async -> Set<String> {
        if isVideo {
            return Set(
                DepthCacheStore.allEntries()
                    .filter(\.meta.completed)
                    .map(\.meta.videoIdentity)
            )
        }
        return await ImageEnhancementTracker.shared.convertedIdentities()
    }

    /// Photos local identifiers with 3D output.
    static func photosAssetIdentifiers(isVideo: Bool) async -> [String] {
        await convertedIdentities(isVideo: isVideo).compactMap { identity in
            guard let url = URL(string: identity) else { return nil }
            return PhotosAssetURL.localIdentifier(from: url)
        }
    }

    /// Stash ids with 3D output.
    ///
    /// Older records can be missing here: an image converted before identities
    /// were recorded only left its URL behind, and that is deliberately not
    /// parsed back into an id. It reappears the next time it is viewed in 3D.
    static func stashIds(isVideo: Bool) async -> [String] {
        await convertedIdentities(isVideo: isVideo).filter(MediaIdentity.isStashID)
    }
}
