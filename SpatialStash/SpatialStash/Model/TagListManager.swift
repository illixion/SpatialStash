/*
 Spatial Stash - Tag List Manager

 Shared observable that mirrors the RoboFrame server's tag list catalog
 plus the local user preference for which list to default to. The
 catalog itself is server-pushed (never persisted on this side); only
 the user's "Default List" choice and last-active recovery hint live in
 UserDefaults.
 */

import Foundation
import os

@MainActor
@Observable
class TagListManager {
    // MARK: - Tag Lists

    /// Mirror of the server's tag list catalog. Reset on every `tagLists`
    /// frame; never persisted locally.
    var tagLists: [[String]] = []

    /// The currently active tag list index.
    private(set) var activeIndex: Int = 0

    /// When set, the viewer starts on this list and server-side tag list
    /// changes are blocked. nil = "Server Decides" mode.
    var defaultIndex: Int? = nil {
        didSet { save() }
    }

    /// Persisted for "Server Decides" recovery on relaunch — tracks the
    /// last user- or server-selected index so it can be restored if the
    /// server is unreachable at next launch.
    private(set) var lastActiveIndex: Int? = nil

    // MARK: - Change Notification

    /// Registered change handlers keyed by engine/window ID.
    /// Called when the active tag list changes so engines can clear
    /// caches and restart fetching.
    private var changeHandlers: [UUID: () -> Void] = [:]

    /// Registered send handlers keyed by engine/window ID. Called only on
    /// *user-initiated* switches so each viewer's WS forwards a `setTagList`
    /// to the server. Server-initiated changes (`handleServerTagListChange`)
    /// skip this to avoid a feedback loop.
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

    /// Whether server-side tag list changes are allowed (no default list set).
    var serverControlEnabled: Bool { defaultIndex == nil }

    // MARK: - Init

    init() {}

    /// Initialize the active index from persisted state.
    func initialize() {
        activeIndex = defaultIndex ?? lastActiveIndex ?? 0
        if activeIndex >= tagLists.count { activeIndex = 0 }
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

    /// Manually switch to a specific tag list. Notifies all registered engines
    /// AND broadcasts the switch to the server via every registered send
    /// handler so other clients (web kiosks, other spatialstash windows)
    /// pick up the change.
    func switchToTagList(_ index: Int) {
        guard index < tagLists.count, index != activeIndex else { return }
        activeIndex = index
        lastActiveIndex = index
        changeVersion += 1
        save()
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

    /// Handle a server-requested tag list change. Returns true if accepted.
    /// Only applies when defaultIndex is nil ("Server Decides" mode).
    @discardableResult
    func handleServerTagListChange(to index: Int) -> Bool {
        guard defaultIndex == nil else { return false }
        guard index < tagLists.count, index != activeIndex else { return false }
        activeIndex = index
        lastActiveIndex = index
        changeVersion += 1
        save()
        notifyChangeHandlers()
        return true
    }

    // MARK: - Persistence
    //
    // Only the user's local preferences are persisted — the server is
    // authoritative on the catalog itself.
    //   - defaultIndex: the user's "Default List" choice (nil = let the
    //     server decide which list is active).
    //   - lastActiveIndex: recovery hint so a relaunch in "Server Decides"
    //     mode lands on the same list it was on previously, before the
    //     server has had a chance to push currentTagList.

    private static let defaultIndexKey = "tagListManager.defaultIndex"
    private static let lastActiveIndexKey = "tagListManager.lastActiveIndex"

    func save() {
        if let idx = defaultIndex {
            UserDefaults.standard.set(idx, forKey: Self.defaultIndexKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultIndexKey)
        }
        if let idx = lastActiveIndex {
            UserDefaults.standard.set(idx, forKey: Self.lastActiveIndexKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastActiveIndexKey)
        }
    }

    func load() {
        if UserDefaults.standard.object(forKey: Self.defaultIndexKey) != nil {
            defaultIndex = UserDefaults.standard.integer(forKey: Self.defaultIndexKey)
        } else {
            defaultIndex = nil
        }
        if UserDefaults.standard.object(forKey: Self.lastActiveIndexKey) != nil {
            lastActiveIndex = UserDefaults.standard.integer(forKey: Self.lastActiveIndexKey)
        } else {
            lastActiveIndex = nil
        }
        initialize()
        AppLogger.remoteViewer.info("TagListManager loaded: defaultIndex=\(self.defaultIndex.map(String.init) ?? "nil", privacy: .public) lastActive=\(self.lastActiveIndex.map(String.init) ?? "nil", privacy: .public)")
    }

    // MARK: - Private

    private func notifyChangeHandlers() {
        for handler in changeHandlers.values {
            handler()
        }
    }
}
