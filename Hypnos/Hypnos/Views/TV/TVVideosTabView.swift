/*
 Hypnos - tvOS Videos tab

 Mirrors `TVPicturesTabView`: a focus-friendly grid over
 `appModel.galleryVideos`, same source/filter/paging as the visionOS/iOS
 Videos tab, tapping a cell opens `TVVideoPlayerView` fullscreen.
 */

#if os(tvOS)

import SwiftUI

struct TVVideosTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var presentedVideo: GalleryVideo?

    private let gridSpacing: CGFloat = 40
    private let preferredCellSize: CGFloat = 320
    private let minColumns = 3

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Videos")
        }
        .fullScreenCover(item: $presentedVideo) { video in
            TVVideoPlayerView(video: video)
        }
        .task {
            if appModel.galleryVideos.isEmpty {
                await appModel.loadInitialVideos()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if appModel.galleryVideos.isEmpty && appModel.isLoadingVideos {
            ProgressView("Loading videos…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appModel.galleryVideos.isEmpty {
            ContentUnavailableView(
                "No Videos",
                systemImage: "video",
                description: Text("This library has nothing to show right now.")
            )
        } else {
            GeometryReader { geo in
                let layout = GridColumnLayout.resolve(
                    width: geo.size.width,
                    preferredCellSize: preferredCellSize,
                    minColumns: minColumns,
                    spacing: gridSpacing
                )
                // 16:9 cells rather than the pictures grid's square ones —
                // a video's own poster aspect, and it reads as "video" at a
                // glance from across the room.
                let cellHeight = layout.columnWidth * 9 / 16
                ScrollView {
                    LazyVGrid(columns: layout.columns, spacing: gridSpacing) {
                        ForEach(appModel.galleryVideos) { video in
                            Button {
                                presentedVideo = video
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    MediaThumbnail(
                                        url: video.thumbnailURL,
                                        side: layout.columnWidth,
                                        placeholderSymbol: "video"
                                    )
                                    .frame(width: layout.columnWidth, height: cellHeight)
                                    .clipped()
                                }
                            }
                            .buttonStyle(.card)
                            .onAppear {
                                if video == appModel.galleryVideos.last, appModel.hasMoreVideoPages {
                                    Task { await appModel.loadNextVideoPage() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 24)
                }
            }
        }
    }
}

#endif
