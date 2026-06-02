/*
 Spatial Stash - Tag List Manager

 Per-window observable tracking which tag list a single slideshow viewer is
 on. The catalog (`tagLists`) and the current list are both server-tracked:
 the RoboFrame backend persists each channel's current list and pushes it
 over the WebSocket. The active index is held per-window so two viewers on
 different channels don't overwrite a shared global value when each gets its
 own channel's `playback.currentList`. This object holds no persistence of
 its own — the server is the source of truth.
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
    /// to the server (which persists it for the channel). Server-initiated
    /// changes (`applyServerIndex`) skip this to avoid a feedback loop.
    private var sendHandlers: [UUID: (Int) -> Void] = [:]

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

    init() {}

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

    /// Manually switch to a specific tag list. Notifies the engine and
    /// broadcasts the switch to the server via the send handler; the server
    /// persists the channel's current list and echoes it back via `playback`.
    func switchToTagList(_ index: Int) {
        guard index < tagLists.count, index != activeIndex else { return }
        activeIndex = index
        changeVersion += 1
        notifyChangeHandlers()
        for handler in sendHandlers.values {
            handler(index)
        }
    }

    /// Cycle to the next tag list.
    func cycleTagList() {
        guard !tagLists.isEmpty else { return }
        let next = (activeIndex + 1) % tagLists.count
        switchToTagList(next)
    }

    /// Apply a server-driven tag list change for this window's channel. Just
    /// performs the change and notifies the engine (no send handler, so no
    /// echo back to the server). Returns true if the index actually changed.
    @discardableResult
    func applyServerIndex(_ index: Int) -> Bool {
        guard index >= 0, index < tagLists.count, index != activeIndex else { return false }
        activeIndex = index
        changeVersion += 1
        notifyChangeHandlers()
        return true
    }

    // MARK: - Private

    private func notifyChangeHandlers() {
        for handler in changeHandlers.values {
            handler()
        }
    }
}
