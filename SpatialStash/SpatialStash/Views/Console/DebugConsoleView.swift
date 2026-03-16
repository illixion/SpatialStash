/*
 Spatial Stash - Debug Console View

 In-app log viewer that reads from the unified logging system.
 Displays log entries with filtering by severity, category, and text search.
 */

import SwiftUI

struct DebugConsoleView: View {
    @State private var logStore = LogStore.shared
    @State private var minimumLevel: LogLevel = .debug
    @State private var selectedCategory: String?
    @State private var searchText = ""
    @State private var autoScroll = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider()
                logList
            }
            .navigationTitle("Console")
        }
        .onAppear {
            logStore.startPolling()
        }
        .onDisappear {
            logStore.stopPolling()
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Level", selection: $minimumLevel) {
                ForEach(LogLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            Picker("Category", selection: $selectedCategory) {
                Text("All Categories").tag(nil as String?)
                ForEach(categories, id: \.self) { category in
                    Text(category).tag(category as String?)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 220)

            TextField("Filter...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            Spacer()

            Toggle(isOn: $autoScroll) {
                Image(systemName: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Auto-scroll to newest")

            Button {
                copyFilteredEntriesToClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .help("Copy filtered entries to clipboard")
            .disabled(filteredEntries.isEmpty)

            Text("\(filteredEntries.count)")
                .foregroundStyle(.secondary)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 40, alignment: .trailing)

            Button(role: .destructive) {
                logStore.clear()
            } label: {
                Image(systemName: "trash")
            }
            .help("Clear log entries")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredEntries) { entry in
                        LogEntryRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .onChange(of: logStore.entries.count) { _, _ in
                if autoScroll, let lastId = filteredEntries.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Filtering

    private var categories: [String] {
        let allCategories = Set(logStore.entries.map(\.category))
        return allCategories.sorted()
    }

    private var filteredEntries: [LogEntry] {
        logStore.entries.filter { entry in
            entry.level >= minimumLevel
            && (selectedCategory == nil || entry.category == selectedCategory)
            && (searchText.isEmpty || entry.message.localizedCaseInsensitiveContains(searchText)
                || entry.category.localizedCaseInsensitiveContains(searchText))
        }
    }

    // MARK: - Copy to Clipboard

    private static let clipboardTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private func copyFilteredEntriesToClipboard() {
        let text = filteredEntries.map { entry in
            let time = Self.clipboardTimeFormatter.string(from: entry.timestamp)
            return "\(time) [\(entry.level.label)] \(entry.category): \(entry.message)"
        }.joined(separator: "\n")

        UIPasteboard.general.string = text
    }
}

// MARK: - Log Entry Row

private struct LogEntryRow: View {
    let entry: LogEntry

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            Text(entry.level.label.prefix(1))
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(levelColor)
                .frame(width: 12)

            Text(entry.category)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .frame(minWidth: 100, alignment: .leading)

            Text(entry.message)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(messageColor)
                .lineLimit(nil)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var levelColor: Color {
        switch entry.level {
        case .error: .red
        case .warning: .orange
        case .notice: .blue
        case .info: .primary
        case .debug: .secondary
        }
    }

    private var messageColor: Color {
        switch entry.level {
        case .error: .red
        case .warning: .orange
        default: .primary
        }
    }
}
