/*
 Spatial Stash - Tag List Manager

 Per-window observable tracking which tag list a single slideshow viewer is
 on. The catalog itself (`tagLists`) is server-pushed over the WebSocket and
 mirrored into each window's manager; the *active* index is per-window so two
 viewers can sit on different lists without overwriting a shared global value.

 The profile's selected list is persisted in `RemoteViewerConfig.tagListIndex`
 (see RemoteViewerModel), not in UserDefaults here. This object holds no
 persistence of its own — it's recreated per window from the profile.
 */

import Foundation
import os

@MainActor
@Observable
class TagListManager {
    // MARK: - Tag Lists

    /// Mirror of the server's tag list catalog for this window. Reset on every
    /// `tagLists` frame; never persisted here.
    var tagLists: [[String]] = []

    /// The currently active tag list index for this window.
    private(set) var activeIndex: Int = 0

    // MARK: - Change Notification

    /// Registered change handlers keyed by engine/window ID. Called when the
    /// active tag list changes so the engine can clear caches and refetch.
    private var changeHandlers: [UUID: () -> Void] = [:]

    /// Registered send handlers keyed by engine/window ID. Called only on
    /// *user-initiated* switches so the viewer's WS forwards a `setTagList`
    /// to the server (claiming the list for its channel). Server-initiated
    /// changes (`applyServerIndex`) skip this to avoid a feedback loop.
    private var sendHandlers: [UUID: (Int) -> Void] = [:]

    /// Called on user-initiated switches so the owning model can persist the
    /// new index into its `RemoteViewerConfig.tagListIndex`.
    var onUserSwitch: ((Int) -> Void)?

    /// Incremented on each tag list switch. Views can observe this
    /// with onChange(of:) for lightweight reactivity.
    var changeVersion: Int = 0

    // MARK: - Computed

    /// The tag query string for the currently active list. Empty when the
    /// server hasn't pushed a catalog yet.
    var activeTagQuery: String {
        guard !tagLists.isEmpty, activeIndex < tagLists.count else { return "" }
        return tagLists[activeIndex].joined(separator: " ")
    }

    // MARK: - Init

    /// - Parameter startIndex: the profile's persisted `tagListIndex`, or 0
    ///   for "Server Decides" (the server's first `playback` will move it).
    init(startIndex: Int = 0) {
        activeIndex = max(0, startIndex)
    }

    /// Clamp the active index after a catalog update so a shrunken catalog
    /// doesn't leave us pointing past the end.
    func clampActiveIndex() {
        if activeIndex >= tagLists.count { activeIndex = max(0, tagLists.count - 1) }
        if tagLists.isEmpty { activeIndex = 0 }
    }

    // MARK: - Registration

    func addChangeHandler(id: UUID, _ handler: @escaping () -> Void) {
        changeHandlers[id] = handler
    }

    func removeChangeHandler(id: UUID) {
        changeHandlers[id] = nil
    }

    func addSendHandler(id: UUID, _ handler: @escaping (Int) -> Void) {
        sendHandlers[id] = handler
    }

    func removeSendHandler(id: UUID) {
        sendHandlers[id] = nil
    }

    // MARK: - Switching

    /// Manually switch to a specific tag list. Notifies the engine, broadcasts
    /// the switch to the server via the send handler (claiming the list for
    /// this window's channel), and asks the owning model to persist the choice
    /// to its profile.
    func switchToTagList(_ index: Int) {
        guard index < tagLists.count, index != activeIndex else { return }
        activeIndex = index
        changeVersion += 1
        notifyChangeHandlers()
        for handler in sendHandlers.values {
            handler(index)
        }
        onUserSwitch?(index)
    }

    /// Cycle to the next tag list.
    func cycleTagList() {
        guard !tagLists.isEmpty else { return }
        let next = (activeIndex + 1) % tagLists.count
        switchToTagList(next)
    }

    /// Apply a server-driven tag list change for this window's channel. The
    /// caller is responsible for the pin/displaySync policy — this just
    /// performs the change and notifies the engine (no send handler, no
    /// persistence). Returns true if the index actually changed.
    @discardableResult
    func applyServerIndex(_ index: Int) -> Bool {
        guard index >= 0, index < tagLists.count, index != activeIndex else { return false }
        activeIndex = index
        changeVersion += 1
        notifyChangeHandlers()
        return true
    }

    /// Set the active index locally without notifying the server. Used when a
    /// pinned window returns to its profile list (e.g. displaySync turns off).
    @discardableResult
    func setActiveIndexLocally(_ index: Int) -> Bool {
        applyServerIndex(index)
    }

    // MARK: - Private

    private func notifyChangeHandlers() {
        for handler in changeHandlers.values {
            handler()
        }
    }
}
