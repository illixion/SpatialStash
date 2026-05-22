/*
 Spatial Stash - Log Store

 Reads app log entries from the unified logging system via OSLogStore
 for display in the in-app debug console. Polls periodically for new entries.
 */

import Foundation
import os
import OSLog

/// Log severity level for in-app console display
enum LogLevel: Int, CaseIterable, Identifiable, Comparable {
    case debug = 0
    case info = 1
    case notice = 2
    case warning = 3
    case error = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .notice: "Notice"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Map from OSLogEntryLog.Level to our LogLevel
    init(osLogLevel: OSLogEntryLog.Level) {
        switch osLogLevel {
        case .debug: self = .debug
        case .info: self = .info
        case .notice: self = .notice
        case .error: self = .error
        case .fault: self = .error
        default: self = .info
        }
    }
}

/// A single captured log entry for in-app display
struct LogEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let category: String
    let level: LogLevel
    let message: String
}

/// Reads logs from the unified logging system using OSLogStore.
/// Polls periodically for new entries while the console is visible.
@Observable
@MainActor
final class LogStore {
    static let shared = LogStore()

    private(set) var entries: [LogEntry] = []
    /// Sorted, deduplicated category names seen so far. Maintained
    /// incrementally so the console's category picker doesn't have to
    /// rebuild a Set from `entries` on every render.
    private(set) var categories: [String] = []
    private(set) var isPolling = false

    private let maxEntries = 2000
    private var lastPollDate: Date?
    private var pollTask: Task<Void, Never>?
    private var categoriesSet: Set<String> = []
    private let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.spatial-stash"

    /// Number of open console views/windows currently observing logs.
    /// Polling runs iff this is > 0 so the tab can stay visible in the
    /// ornament without paying the OSLogStore poll cost when nobody is
    /// looking.
    private var viewerCount: Int = 0

    /// Nonisolated mirror of `viewerCount > 0` so `AppLogger` can cheaply
    /// check from any thread whether to promote `.debug` calls to `.info`
    /// (the unified log drops `.debug` from the persistent store by default,
    /// hiding them from OSLogStore polling and the in-app console).
    nonisolated static var hasActiveViewers: Bool {
        activeViewersFlag.withLock { $0 }
    }

    nonisolated private static let activeViewersFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    private init() {}

    /// Register a console view/window as active. Starts polling on first
    /// subscriber.
    func addViewer() {
        viewerCount += 1
        if viewerCount == 1 {
            Self.activeViewersFlag.withLock { $0 = true }
            startPolling()
        }
    }

    /// Unregister a console view/window. Stops polling and releases
    /// captured entries once the last subscriber leaves.
    func removeViewer() {
        guard viewerCount > 0 else { return }
        viewerCount -= 1
        if viewerCount == 0 {
            Self.activeViewersFlag.withLock { $0 = false }
            stopPolling()
            entries.removeAll()
            categoriesSet.removeAll()
            categories.removeAll()
            lastPollDate = nil
        }
    }

    private func startPolling() {
        guard !isPolling else { return }
        isPolling = true

        pollTask = Task { [weak self] in
            // First poll produces the initial 60s of history. Running it
            // through the same detached path keeps the main thread free
            // during the cold open.
            await self?.performFetch()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await self?.performFetch()
            }
        }
    }

    private func stopPolling() {
        isPolling = false
        pollTask?.cancel()
        pollTask = nil
    }

    /// Clear all entries and reset the poll date
    func clear() {
        entries.removeAll()
        categoriesSet.removeAll()
        categories.removeAll()
        lastPollDate = Date()
    }

    /// Run one fetch cycle. The OSLogStore read is the expensive part and
    /// runs on a detached utility task so it doesn't block the main actor
    /// while the console is being rendered.
    private func performFetch() async {
        let since = lastPollDate
        let subsystem = self.subsystem
        let result = await Task.detached(priority: .utility) {
            Self.readEntries(since: since, subsystem: subsystem)
        }.value
        apply(result)
    }

    /// Pull new entries from the unified log store. Pure/nonisolated so
    /// it can execute off the main thread.
    nonisolated private static func readEntries(
        since date: Date?,
        subsystem: String
    ) -> (newEntries: [LogEntry], latestDate: Date?) {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)

            let position: OSLogPosition
            if let date {
                position = store.position(date: date)
            } else {
                position = store.position(date: Date().addingTimeInterval(-60))
            }

            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let logEntries = try store.getEntries(at: position, matching: predicate)

            var newEntries: [LogEntry] = []
            var latestDate = date

            for entry in logEntries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                if let date, logEntry.date <= date { continue }

                newEntries.append(LogEntry(
                    id: UUID(),
                    timestamp: logEntry.date,
                    category: logEntry.category,
                    level: LogLevel(osLogLevel: logEntry.level),
                    message: logEntry.composedMessage
                ))

                if latestDate == nil || logEntry.date > latestDate! {
                    latestDate = logEntry.date
                }
            }

            return (newEntries, latestDate)
        } catch {
            return ([], date)
        }
    }

    private func apply(_ result: (newEntries: [LogEntry], latestDate: Date?)) {
        if !result.newEntries.isEmpty {
            entries.append(contentsOf: result.newEntries)
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }

            var addedCategory = false
            for entry in result.newEntries {
                if categoriesSet.insert(entry.category).inserted {
                    addedCategory = true
                }
            }
            if addedCategory {
                categories = categoriesSet.sorted()
            }
        }

        if let latestDate = result.latestDate {
            lastPollDate = latestDate
        }
    }
}
