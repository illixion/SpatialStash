/*
 Spatial Stash - Log Store

 Reads app log entries from the unified logging system via OSLogStore
 for display in the in-app debug console. Polls periodically for new entries.
 */

import Foundation
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
    private(set) var isPolling = false

    private let maxEntries = 2000
    private var lastPollDate: Date?
    private var pollTask: Task<Void, Never>?
    private var delayedStopTask: Task<Void, Never>?
    private let subsystem = Bundle.main.bundleIdentifier ?? "com.illixion.spatial-stash"

    /// How long polling continues after navigating away from the console tab
    private static let pollingLingerDuration: Duration = .seconds(15)

    private init() {}

    /// Start polling for new log entries
    func startPolling() {
        // Cancel any pending delayed stop — user returned to the console tab
        delayedStopTask?.cancel()
        delayedStopTask = nil

        guard !isPolling else { return }
        isPolling = true

        // Fetch historical entries on first start
        if entries.isEmpty {
            fetchEntries(since: nil)
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                self?.fetchEntries(since: self?.lastPollDate)
            }
        }
    }

    /// Schedule polling to stop after a delay.
    /// Allows logs generated while using other tabs to still be captured.
    func stopPolling() {
        delayedStopTask?.cancel()
        delayedStopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pollingLingerDuration)
            guard !Task.isCancelled else { return }
            self?.stopPollingImmediately()
        }
    }

    /// Stop polling immediately without delay
    private func stopPollingImmediately() {
        isPolling = false
        pollTask?.cancel()
        pollTask = nil
        delayedStopTask?.cancel()
        delayedStopTask = nil
    }

    /// Clear all entries and reset the poll date
    func clear() {
        entries.removeAll()
        lastPollDate = Date()
    }

    /// Stop polling immediately and release all stored entries to free memory.
    /// Called when the debug console is disabled in settings.
    func stopAndClear() {
        stopPollingImmediately()
        entries.removeAll()
        lastPollDate = nil
    }

    /// Fetch entries from OSLogStore, optionally filtering to entries after a date
    private func fetchEntries(since date: Date?) {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)

            let position: OSLogPosition?
            if let date {
                position = store.position(date: date)
            } else {
                // Fetch last 60 seconds of history on initial load
                position = store.position(date: Date().addingTimeInterval(-60))
            }

            let predicate = NSPredicate(format: "subsystem == %@", subsystem)

            let logEntries = try store.getEntries(at: position, matching: predicate)
            var newEntries: [LogEntry] = []
            var latestDate = date

            for entry in logEntries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }

                // Skip entries we've already seen (date-based dedup)
                if let date, logEntry.date <= date {
                    continue
                }

                let level = LogLevel(osLogLevel: logEntry.level)

                newEntries.append(LogEntry(
                    id: UUID(),
                    timestamp: logEntry.date,
                    category: logEntry.category,
                    level: level,
                    message: logEntry.composedMessage
                ))

                if latestDate == nil || logEntry.date > latestDate! {
                    latestDate = logEntry.date
                }
            }

            if !newEntries.isEmpty {
                entries.append(contentsOf: newEntries)

                // Prune oldest entries if over limit
                if entries.count > maxEntries {
                    entries.removeFirst(entries.count - maxEntries)
                }
            }

            if let latestDate {
                lastPollDate = latestDate
            }
        } catch {
            // OSLogStore can fail in some environments — silently ignore
        }
    }
}
