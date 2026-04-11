/*
 Spatial Stash - Tag List Manager

 Shared observable that owns tag lists and the active tag list index.
 All slideshow windows share a single TagListManager so tag list
 switches are synchronized across windows. Persisted to UserDefaults
 independently from saved remote viewer configurations.
 */

import Foundation
import os

@MainActor
@Observable
class TagListManager {
    // MARK: - Tag Lists

    /// The array of tag lists. Each list is an array of tag strings.
    var tagLists: [[String]] = [["order:random"]] {
        didSet { save() }
    }

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

    /// Incremented on each tag list switch. Views can observe this
    /// with onChange(of:) for lightweight reactivity.
    var changeVersion: Int = 0

    // MARK: - Computed

    /// The tag query string for the currently active list.
    var activeTagQuery: String {
        guard !tagLists.isEmpty, activeIndex < tagLists.count else { return "order:random" }
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

    // MARK: - Switching

    /// Manually switch to a specific tag list. Notifies all registered engines.
    func switchToTagList(_ index: Int) {
        guard index < tagLists.count, index != activeIndex else { return }
        activeIndex = index
        lastActiveIndex = index
        changeVersion += 1
        save()
        notifyChangeHandlers()
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

    static let tagListsKeyPublic = "tagListManager.tagLists"
    private static let tagListsKey = tagListsKeyPublic
    private static let defaultIndexKey = "tagListManager.defaultIndex"
    private static let lastActiveIndexKey = "tagListManager.lastActiveIndex"

    func save() {
        if let data = try? JSONEncoder().encode(tagLists) {
            UserDefaults.standard.set(data, forKey: Self.tagListsKey)
        }
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
        if let data = UserDefaults.standard.data(forKey: Self.tagListsKey),
           let lists = try? JSONDecoder().decode([[String]].self, from: data),
           !lists.isEmpty {
            tagLists = lists
        }
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
        AppLogger.remoteViewer.info("TagListManager loaded: \(self.tagLists.count, privacy: .public) lists, active=\(self.activeIndex, privacy: .public)")
    }

    /// Import tag lists from a legacy RemoteViewerConfig (migration).
    func importFromConfig(_ config: RemoteViewerConfig) {
        if !config.legacyTagLists.isEmpty {
            tagLists = config.legacyTagLists
        }
        defaultIndex = config.legacyDefaultTagListIndex
        lastActiveIndex = config.legacyLastActiveTagListIndex
        initialize()
        save()
    }

    // MARK: - Private

    private func notifyChangeHandlers() {
        for handler in changeHandlers.values {
            handler()
        }
    }
}
