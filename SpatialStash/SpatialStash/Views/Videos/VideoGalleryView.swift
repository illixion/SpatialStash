/*
 Spatial Stash - Video Gallery View

 Grid view for browsing videos with lazy loading.
 Supports multi-select mode for bulk operations.
 */

import SwiftUI

struct VideoGalleryView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.pushWindow) private var pushWindow
    @Environment(\.openWindow) private var openWindow

    @State private var showBulkDeleteConfirmation = false

    let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 350), spacing: 16)
    ]

    var body: some View {
        Group {
            if appModel.galleryVideos.isEmpty && appModel.isLoadingVideos {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                    Text("Loading videos...")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appModel.galleryVideos.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text("No videos available")
                        .font(.title2)
                    Text("Configure your Stash server in Settings to browse videos.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(appModel.galleryVideos) { video in
                                thumbnailCell(for: video)
                                    .id(video.id)
                                    .onAppear {
                                        if video == appModel.galleryVideos.last && appModel.hasMoreVideoPages {
                                            Task {
                                                await appModel.loadNextVideoPage()
                                            }
                                        }
                                        prefetchThumbnails(around: video)
                                    }
                            }

                            if appModel.isLoadingVideos {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                            }
                        }
                        .padding()
                    }
                    .refreshable {
                        await appModel.loadInitialVideos()
                    }
                    .onAppear {
                        if let lastViewedId = appModel.lastViewedVideoId {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(lastViewedId, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            if appModel.isSelectingVideos {
                selectionToolbar
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if appModel.isSelectingVideos {
                        appModel.exitVideoSelection()
                    } else {
                        appModel.isSelectingVideos = true
                    }
                } label: {
                    Text(appModel.isSelectingVideos ? "Cancel" : "Select")
                }
            }
        }
        .task {
            if appModel.galleryVideos.isEmpty {
                await appModel.loadInitialVideos()
            }
        }
        .confirmationDialog(
            "Delete \(appModel.selectedVideoIds.count) Video\(appModel.selectedVideoIds.count == 1 ? "" : "s")",
            isPresented: $showBulkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove from Stash", role: .destructive) {
                Task { await bulkDelete(deleteFile: false) }
            }
            Button("Delete Files from Disk", role: .destructive) {
                Task { await bulkDelete(deleteFile: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func thumbnailCell(for video: GalleryVideo) -> some View {
        if appModel.isSelectingVideos {
            VideoThumbnailView(video: video)
                .overlay(alignment: .topTrailing) {
                    let isSelected = appModel.selectedVideoIds.contains(video.stashId)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundColor(isSelected ? .accentColor : .white)
                        .shadow(radius: 2)
                        .padding(8)
                }
                .onTapGesture {
                    if appModel.selectedVideoIds.contains(video.stashId) {
                        appModel.selectedVideoIds.remove(video.stashId)
                    } else {
                        appModel.selectedVideoIds.insert(video.stashId)
                    }
                }
        } else {
            VideoThumbnailView(video: video)
                .onTapGesture {
                    openVideoDetail(video)
                }
        }
    }

    // MARK: - Selection Toolbar

    private var selectionToolbar: some View {
        HStack(spacing: 20) {
            Button {
                let allIds = Set(appModel.galleryVideos.map(\.stashId))
                if appModel.selectedVideoIds == allIds {
                    appModel.selectedVideoIds.removeAll()
                } else {
                    appModel.selectedVideoIds = allIds
                }
            } label: {
                let allIds = Set(appModel.galleryVideos.map(\.stashId))
                Text(appModel.selectedVideoIds == allIds ? "Deselect All" : "Select All")
            }

            Spacer()

            Text("\(appModel.selectedVideoIds.count) selected")
                .font(.callout)
                .foregroundColor(.secondary)

            Spacer()

            Button("Delete", role: .destructive) {
                showBulkDeleteConfirmation = true
            }
            .disabled(appModel.selectedVideoIds.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }

    // MARK: - Bulk Delete

    private func bulkDelete(deleteFile: Bool) async {
        let ids = Array(appModel.selectedVideoIds)
        guard !ids.isEmpty else { return }
        do {
            try await appModel.apiClient.destroyScenes(ids: ids, deleteFile: deleteFile)
            appModel.removeDeletedVideos(stashIds: Set(ids))
            if appModel.selectedVideoIds.isEmpty {
                appModel.exitVideoSelection()
            }
        } catch {}
    }

    // MARK: - Helpers

    private func prefetchThumbnails(around video: GalleryVideo) {
        guard let index = appModel.galleryVideos.firstIndex(where: { $0.id == video.id }) else { return }
        let videos = appModel.galleryVideos
        let prefetchCount = 12
        let endIndex = min(index + prefetchCount, videos.count)
        guard endIndex > index + 1 else { return }

        let upcoming = videos[(index + 1)..<endIndex]
        for upcoming in upcoming {
            let url = upcoming.thumbnailURL
            Task.detached(priority: .utility) {
                if await ThumbnailCache.shared.isCached(for: url) { return }
                _ = await ImageLoader.shared.loadRemoteThumbnailCached(from: url, crop: VideoThumbnailView.cropTo16x9)
            }
        }
    }

    private func openVideoDetail(_ video: GalleryVideo) {
        appModel.lastViewedVideoId = video.id
        if appModel.openMediaInNewWindows {
            openWindow(id: "video-detail", value: VideoWindowValue(video: video))
        } else {
            pushWindow(id: "video-detail", value: VideoWindowValue(video: video, wasPushed: true))
        }
    }
}
