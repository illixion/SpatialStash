/*
 Spatial Stash - Video Ornaments View

 Controls for the video player including navigation, format toggle, and back button.

 Layout: [Gallery] | [< N/M >] | [ViewMode v] | [Info] | [Share] | [... More v] | [Title]
 */

import SwiftUI

struct VideoOrnamentsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    let videoCount: Int
    /// The video this ornament controls (used for button visibility and data display
    /// independent of `appModel.selectedVideo`, which may be nil during window transitions)
    let video: GalleryVideo
    /// Whether this ornament belongs to a pushed (gallery-navigated) window
    let wasPushed: Bool
    /// Action to show the main gallery window
    var onGalleryButtonTap: () -> Void
    /// Custom pop-out action (used by pushed windows to open a new window and dismiss self)
    var onPopOut: (() -> Void)? = nil
    @State private var showMediaInfo = false
    @State private var showAdjustmentsPopover = false

    var body: some View {
        VStack {
            HStack(spacing: 16) {
                // Gallery button
                Button(action: onGalleryButtonTap) {
                    Image(systemName: "square.grid.2x2")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help(wasPushed ? "Videos" : "Show Gallery")

                Divider()
                    .frame(height: 24)

                // Previous video
                Button {
                    appModel.previousVideo()
                } label: {
                    Image(systemName: "arrow.left.circle")
                }
                .disabled(!appModel.hasPreviousVideo)

                // Video counter
                if appModel.currentVideoPosition > 0 {
                    Text("\(appModel.currentVideoPosition) / \(videoCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(minWidth: 60)
                }

                // Next video
                Button {
                    appModel.nextVideo()
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .disabled(!appModel.hasNextVideo)

                // View mode toggle (2D/3D)
                Divider()
                    .frame(height: 24)

                viewModeMenu(for: video)

                // Info button (rating & metadata)
                Divider()
                    .frame(height: 24)

                infoButton

                // Share button
                Divider()
                    .frame(height: 24)

                shareButton

                // More menu (adjustments, flip, slideshow, pop out)
                Divider()
                    .frame(height: 24)

                moreMenu

                // Video title if available
                if let title = video.title, !title.isEmpty {
                    Divider()
                        .frame(height: 24)
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding()
        }
        .glassBackgroundEffect()
        .onChange(of: showMediaInfo) { _, isOpen in
            if isOpen { appModel.cancelAutoHideTimer() }
            else { appModel.startAutoHideTimer() }
        }
        .onChange(of: showAdjustmentsPopover) { _, isOpen in
            if isOpen { appModel.cancelAutoHideTimer() }
            else { appModel.startAutoHideTimer() }
        }
    }

    /// The video to read live data from (rating, o-counter).
    /// Prefers appModel.selectedVideo for up-to-date values, falls back to the passed video.
    private var currentVideo: GalleryVideo {
        appModel.selectedVideo ?? video
    }

    /// Effective adjustments: use per-video session if modified, otherwise global
    private var effectiveVideoAdjustments: VisualAdjustments {
        appModel.videoVisualAdjustments.isModified ? appModel.videoVisualAdjustments : appModel.globalVisualAdjustments
    }

    // MARK: - Info Button

    private var infoButton: some View {
        Button {
            showMediaInfo.toggle()
        } label: {
            Image(systemName: currentVideo.rating100 != nil ? "info.circle.fill" : "info.circle")
                .font(.title3)
                .foregroundColor(currentVideo.rating100 != nil ? .yellow : nil)
        }
        .buttonStyle(.borderless)
        .help("Info")
        .sheet(isPresented: $showMediaInfo) {
            MediaDetailSheet(
                mediaType: .scene(stashId: currentVideo.stashId),
                onDelete: {
                    if let idx = appModel.galleryVideos.firstIndex(where: { $0.stashId == currentVideo.stashId }) {
                        appModel.galleryVideos.remove(at: idx)
                    }
                    appModel.dismissVideoDetail()
                }
            )
        }
    }

    // MARK: - Share

    private var shareButton: some View {
        Button {
            if appModel.selectedVideo == nil {
                appModel.selectVideoForDetail(video)
            }
            Task {
                await appModel.shareVideo()
            }
        } label: {
            Group {
                if appModel.isPreparingVideoShare {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(appModel.isPreparingVideoShare)
        .help("Share")
        .sheet(isPresented: Binding(
            get: { appModel.videoShareFileURL != nil },
            set: { if !$0 { appModel.videoShareFileURL = nil } }
        )) {
            appModel.startAutoHideTimer()
        } content: {
            if let url = appModel.videoShareFileURL {
                ActivityViewController(
                    activityItems: [url],
                    isPresented: Binding(
                        get: { appModel.videoShareFileURL != nil },
                        set: { if !$0 { appModel.videoShareFileURL = nil } }
                    )
                )
            }
        }
    }

    // MARK: - More Menu

    private var moreMenu: some View {
        Menu {
            // Visual Adjustments
            Button {
                showAdjustmentsPopover.toggle()
            } label: {
                Label("Adjustments", systemImage: "slider.horizontal.3")
            }

            // Flip video
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    appModel.isVideoFlipped.toggle()
                }
            } label: {
                Label(
                    appModel.isVideoFlipped ? "Unflip" : "Flip",
                    systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right"
                )
            }

            // Slideshow
            Button {
                launchGallerySlideshow()
            } label: {
                Label("Slideshow", systemImage: "play.fill")
            }

            // Pop out (only for pushed windows)
            if wasPushed {
                Divider()

                Button {
                    if let onPopOut {
                        onPopOut()
                    } else {
                        popOutVideo()
                    }
                } label: {
                    Label("Pop Out", systemImage: "rectangle.portrait.and.arrow.forward")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .padding(6)
                .background(moreMenuHighlighted ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .help("More")
        .popover(isPresented: $showAdjustmentsPopover) {
            VisualAdjustmentsPopover(
                currentAdjustments: Binding(
                    get: { appModel.videoVisualAdjustments },
                    set: { appModel.videoVisualAdjustments = $0 }
                ),
                globalAdjustments: Binding(
                    get: { appModel.globalVisualAdjustments },
                    set: { appModel.globalVisualAdjustments = $0 }
                ),
                showAutoEnhance: false
            )
        }
    }

    /// Whether the More menu button should show a highlight
    private var moreMenuHighlighted: Bool {
        effectiveVideoAdjustments.isModified || appModel.isVideoFlipped
    }

    // MARK: - Helpers

    private func launchGallerySlideshow() {
        let config: RemoteViewerConfig
        if let existing = appModel.gallerySlideshowConfig {
            config = existing
        } else {
            var newConfig = RemoteViewerConfig(name: "Gallery Slideshow")
            newConfig.apiEndpoint = ""
            newConfig.delay = appModel.slideshowDelay
            newConfig.showClock = false
            newConfig.transparentBackground = true
            appModel.gallerySlideshowConfig = newConfig
            config = newConfig
        }
        openWindow(id: "remote-viewer", value: RemoteViewerWindowValue(configId: config.id))
    }

    private func popOutVideo() {
        let windowValue = VideoWindowValue(
            video: currentVideo,
            stereoscopicOverride: appModel.videoStereoscopicOverride,
            video3DSettings: appModel.video3DSettings
        )
        openWindow(id: "video-detail", value: windowValue)
        appModel.dismissVideoDetail()
    }

    // MARK: - View Mode Menu

    @ViewBuilder
    private func viewModeMenu(for video: GalleryVideo) -> some View {
        Menu {
            Button {
                appModel.videoStereoscopicOverride = false
            } label: {
                HStack {
                    Text("2D")
                    if !shouldUse3DMode {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            Button {
                enable3DMode(for: video)
            } label: {
                HStack {
                    Text("3D")
                    if shouldUse3DMode {
                        Image(systemName: "checkmark")
                    }
                }
            }

            if shouldUse3DMode {
                Divider()

                Button {
                    appModel.showVideo3DSettingsSheet = true
                } label: {
                    Label("Edit 3D Settings", systemImage: "slider.horizontal.3")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: currentModeIcon)
                Text(currentModeLabel)
                    .font(.caption)
                if shouldUse3DMode {
                    if let settings = appModel.video3DSettings {
                        Text("(\(settings.format.shortLabel))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else if let format = video.stereoscopicFormat {
                        Text("(\(format.shortLabel))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.2))
            .cornerRadius(6)
        }
    }

    private var shouldUse3DMode: Bool {
        if appModel.videoStereoscopicOverride == false {
            return false
        }
        if appModel.videoStereoscopicOverride == true || appModel.video3DSettings != nil {
            return true
        }
        return currentVideo.isStereoscopic
    }

    private func enable3DMode(for video: GalleryVideo) {
        Task {
            if let savedSettings = await Video3DSettingsTracker.shared.loadSettings(videoId: video.stashId) {
                await MainActor.run {
                    appModel.video3DSettings = savedSettings
                    appModel.videoStereoscopicOverride = true
                }
                return
            }

            if let tagSettings = Video3DSettings.from(video: video) {
                await MainActor.run {
                    appModel.video3DSettings = tagSettings
                    appModel.videoStereoscopicOverride = true
                }
                return
            }

            await MainActor.run {
                appModel.showVideo3DSettingsSheet = true
            }
        }
    }

    private var currentModeIcon: String {
        shouldUse3DMode ? "view.3d" : "view.2d"
    }

    private var currentModeLabel: String {
        shouldUse3DMode ? "3D" : "2D"
    }
}
