/*
 Spatial Stash - Video Gallery View

 Grid view for browsing videos with lazy loading.
 */

import SwiftUI

struct VideoGalleryView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.pushWindow) private var pushWindow
    @Environment(\.openWindow) private var openWindow

    let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 350), spacing: 16)
    ]

    var body: some View {
        Group {
            if appModel.galleryVideos.isEmpty && appModel.isLoadingVideos {
                // Loading state
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                    Text("Loading videos...")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appModel.galleryVideos.isEmpty {
                // Empty state - show message about configuring Stash
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
                // Video grid with scroll position preservation
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(appModel.galleryVideos) { video in
                                VideoThumbnailView(video: video)
                                    .id(video.id)
                                    .onTapGesture {
                                        openVideoDetail(video)
                                    }
                                    .onAppear {
                                        // Lazy loading trigger
                                        if video == appModel.galleryVideos.last && appModel.hasMoreVideoPages {
                                            Task {
                                                await appModel.loadNextVideoPage()
                                            }
                                        }
                                        // Prefetch upcoming thumbnails
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
                        // Restore scroll position when returning from detail view
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
        .task {
            if appModel.galleryVideos.isEmpty {
                await appModel.loadInitialVideos()
            }
        }
    }

    /// Prefetch thumbnails for items ahead of the currently appearing item.
    /// Covers ~2-3 rows beyond the visible area so thumbnails are cached before scrolling reveals them.
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
                // Skip if already cached in ThumbnailCache
                if await ThumbnailCache.shared.isCached(for: url) { return }
                // Warm the cache — result is discarded, but ThumbnailCache stores it
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
