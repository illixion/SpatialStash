/*
 Spatial Stash - Albums Tab

 Browses the containers of whichever library is in force: Photos albums and smart
 albums, or Stash galleries.

 Opening one applies it as a filter and moves to the Pictures or Videos grid, so
 there is no second content pipeline here — the whole existing path does the work,
 including paging, sort and the rest of the filter. See `MediaContainer`.

 The media-kind picker only appears for Photos, because a Stash gallery holds
 images and there is nothing to browse on the Videos side.
 */

import SwiftUI
import UIKit

struct AlbumsTabView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MainWindowModel.self) private var windowModel

    /// Which media kind the browser is showing. Its own state rather than
    /// `lastContentTab`: a browser should say what it is listing, and inheriting
    /// it invisibly from wherever the user last was is a poor way to be told.
    @State private var isVideo = false
    @State private var query = ""

    private let gridSpacing: CGFloat = 20
    private let preferredCellSize: CGFloat = 200
    private let minColumns = 3

    private var isPhotosLibrary: Bool {
        appModel.effectiveLibrarySource == .photos
    }

    private var filteredContainers: [MediaContainer] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return appModel.mediaContainers }
        return appModel.mediaContainers.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: taskKey) {
            await appModel.loadMediaContainers(isVideo: isVideo)
        }
    }

    /// Reloads on anything that changes what should be listed. The index
    /// generation is only part of it under Photos — it bumps regardless of the
    /// library in force, and refetching a server's galleries because the local
    /// photo index moved would be noise.
    private var taskKey: String {
        let indexGeneration = isPhotosLibrary ? PhotosLibraryIndexer.shared.generation : 0
        return "\(appModel.effectiveLibrarySource.rawValue)-\(isVideo)-\(indexGeneration)"
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Label(appModel.effectiveLibrarySource.displayName,
                  systemImage: appModel.effectiveLibrarySource.symbolName)
                .font(.headline)

            if isPhotosLibrary {
                Picker("Showing", selection: $isVideo) {
                    Text("Photos").tag(false)
                    Text("Videos").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }

            Spacer()

            if appModel.mediaContainers.count > 8 {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 280)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if appModel.isLoadingMediaContainers && appModel.mediaContainers.isEmpty {
            MediaLibraryMessageView(icon: "rectangle.stack",
                                    title: "Loading Albums",
                                    message: "Reading your \(isPhotosLibrary ? "albums" : "galleries").")
        } else if appModel.mediaContainers.isEmpty {
            emptyState
        } else if filteredContainers.isEmpty {
            MediaLibraryMessageView(icon: "magnifyingglass",
                                    title: "No Matches",
                                    message: "No albums match \"\(query)\".")
        } else {
            grid
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !isPhotosLibrary && isVideo {
            // Not a failure: Stash galleries group images, and scenes are not in
            // them. Explaining that beats an empty grid.
            MediaLibraryMessageView(
                icon: "video.slash",
                title: "No Video Galleries",
                message: "Stash galleries hold images. Use the Filters tab to narrow videos by tag, performer or studio."
            )
        } else if isPhotosLibrary, let indexing = PhotosLibraryIndexer.shared.blockingMessage {
            MediaLibraryMessageView(icon: "hourglass",
                                    title: "Indexing Your Library",
                                    message: indexing)
        } else {
            MediaLibraryMessageView(
                icon: "rectangle.stack",
                title: isPhotosLibrary ? "No Albums" : "No Galleries",
                message: isPhotosLibrary
                    ? "No albums contain \(isVideo ? "videos" : "photos") yet."
                    : "This server has no galleries."
            )
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let layout = GridColumnLayout.resolve(width: geo.size.width - 48,
                                                 preferredCellSize: preferredCellSize,
                                                 minColumns: minColumns,
                                                 spacing: gridSpacing)
            ScrollView {
                LazyVGrid(columns: layout.columns, spacing: gridSpacing) {
                    ForEach(filteredContainers) { container in
                        MediaContainerCard(
                            container: container,
                            side: layout.columnWidth,
                            isApplied: appModel.isContainerApplied(container, isVideo: isVideo)
                        ) {
                            open(container)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
    }

    private func open(_ container: MediaContainer) {
        appModel.applyContainer(container, isVideo: isVideo)
        let destination: Tab = isVideo ? .videos : .pictures
        windowModel.lastContentTab = destination
        windowModel.selectedTab = destination
    }
}

// MARK: - Card

struct MediaContainerCard: View {
    let container: MediaContainer
    let side: CGFloat
    let isApplied: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                cover
                Text(container.name)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(container.kind.isSecondary ? .secondary : .primary)
                Text("\(container.count) item\(container.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    private var cover: some View {
        ZStack(alignment: .topTrailing) {
            MediaThumbnail(url: container.coverURL,
                           side: side,
                           placeholderSymbol: container.kind.symbolName)
            if isApplied {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .background(Circle().fill(.white))
                    .padding(8)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isApplied ? Color.accentColor : .clear, lineWidth: 3)
        }
    }
}
