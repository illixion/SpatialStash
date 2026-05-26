/*
 Spatial Stash - Restored Window Tracker

 Persists the set of pop-out window value UUIDs that have been opened at least
 once. visionOS restores wall-snapped windows after a reboot with the same
 Codable value (and thus the same UUID), so windows whose UUID is already in
 the set are system-restored rather than user-opened — viewers use this to
 start with ornaments hidden and skip the initial reveal.
 */

import Foundation

@MainActor
enum RestoredWindowTracker {
    private static let defaultsKey = "RestoredWindowTracker.seenWindowIDs"
    private static let maxEntries = 256

    private static var seen: Set<UUID> = loadFromDefaults()

    /// Returns true if this window value has been started before (i.e. visionOS
    /// is restoring it after an app/device launch).
    static func isRestored(_ id: UUID) -> Bool {
        seen.contains(id)
    }

    /// Mark a window value as seen. Call on first `onAppear` so subsequent
    /// restorations of the same window are recognized.
    static func markSeen(_ id: UUID) {
        guard !seen.contains(id) else { return }
        seen.insert(id)
        // Bound storage so dismissed pop-outs don't accumulate forever.
        // Pop-out UUIDs that aren't in any restorable scene will eventually
        // age out; the worst case if a still-snapped window is evicted is one
        // extra ornament reveal on next restore.
        if seen.count > maxEntries {
            seen = Set(seen.shuffled().prefix(maxEntries))
        }
        UserDefaults.standard.set(seen.map(\.uuidString), forKey: defaultsKey)
    }

    private static func loadFromDefaults() -> Set<UUID> {
        guard let raw = UserDefaults.standard.array(forKey: defaultsKey) as? [String] else {
            return []
        }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }
}
