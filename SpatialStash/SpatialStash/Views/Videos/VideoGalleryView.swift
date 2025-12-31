/*
 Spatial Stash - Video Gallery View

 Grid view for browsing videos with lazy loading.
 */

import SwiftUI

struct VideoGalleryView: View {
    @Environment(AppModel.self) private var appModel

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
                                        appModel.selectVideoForDetail(video)
                                    }
                                    .onAppear {
                                        // Lazy loading trigger
                                        if video == appModel.galleryVideos.last && appModel.hasMoreVideoPages {
                                            Task {
                                                await appModel.loadNextVideoPage()
                                            }
                                        }
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
}
