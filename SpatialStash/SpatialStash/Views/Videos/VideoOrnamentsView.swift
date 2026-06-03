/*
 Spatial Stash - Video Ornaments View

 Controls for the video player including navigation, format toggle, and back button.

 Layout: [Gallery] | [< N/M >] | [ViewMode v] | [A-B Loop] | [Info] | [Share] | [... More v] | [Title]
 The [A-B Loop] button is only shown when the 2D web player is active.
 The More menu holds Adjustments (opens the enhancements popover, which now
 includes Flip), Slideshow, and Pop Out (pushed only).
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
    /// Per-window A-B loop controller. The button is only shown for the 2D web player.
    let loopController: VideoLoopController
    /// Whether the host is currently rendering in stereoscopic mode (hides the A-B loop button).
    let isStereoscopicMode: Bool
    /// Action to show the main gallery window
    var onGalleryButtonTap: () -> Void
    /// Custom pop-out action (used by pushed windows to open a new window and dismiss self)
    var onPopOut: (() -> Void)? = nil
    /// Called with `true` when a Menu drop-down, popover, or sheet opens
    /// and `false` when it closes. The host uses this to pause its
    /// auto-hide timer so the ornament doesn't vanish out from under
    /// the user's selection.
    var onChromeBlockingChange: ((Bool) -> Void)? = nil
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

                // A-B Loop button (only available in 2D web player mode)
                if !isStereoscopicMode {
                    Divider()
                        .frame(height: 24)
                    abLoopButton
                }

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

    // MARK: - A-B Loop Button

    private var abLoopButton: some View {
        Button {
            Task { await loopController.handleButtonTap() }
        } label: {
            Image(systemName: loopController.iconName)
                .font(.title3)
                .foregroundColor(loopController.isEngaged ? .accentColor : nil)
        }
        .buttonStyle(.borderless)
        .help(loopController.helpText)
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
            // Tracker fires onAppear when the Menu's content panel
            // appears (i.e. the menu opens) and onDisappear when it
            // closes — lets us pause the host's auto-hide timer so the
            // ornament doesn't vanish while the user is browsing the
            // menu. Same pattern as PhotoOrnamentView.moreMenu.
            Group {
                // Visual Adjustments
                Button {
                    showAdjustmentsPopover.toggle()
                } label: {
                    Label("Adjustments", systemImage: "slider.horizontal.3")
                }

                // Slideshow
                Button {
                    launchVideoSlideshow()
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
            }
            .onAppear { onChromeBlockingChange?(true) }
            .onDisappear { onChromeBlockingChange?(false) }
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
                showAutoEnhance: false,
                showFlip: true,
                isImageFlipped: appModel.isVideoFlipped,
                onToggleFlip: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        appModel.isVideoFlipped.toggle()
                    }
                }
            )
        }
        .onChange(of: showAdjustmentsPopover) { _, isOpen in
            onChromeBlockingChange?(isOpen)
        }
    }

    /// Whether the More menu button should show a highlight
    private var moreMenuHighlighted: Bool {
        effectiveVideoAdjustments.isModified || appModel.isVideoFlipped
    }

    // MARK: - Helpers

    private func launchVideoSlideshow() {
        let config: RemoteViewerConfig
        if let existing = appModel.videoSlideshowConfig {
            config = existing
        } else {
            var newConfig = RemoteViewerConfig(name: "Video Slideshow")
            newConfig.apiEndpoint = ""
            appModel.applySlideshowDefaults(to: &newConfig)
            // Spatial 3D is image-only — never engage it for a video slideshow.
            newConfig.slideshow3DMode = .off
            appModel.videoSlideshowConfig = newConfig
            config = newConfig
        }
        // Run the slideshow over the same video source/filter being browsed.
        appModel.pendingVideoSlideshowSource = VideoSlideshowSourceOverride(
            videoSource: appModel.videoSource,
            filter: appModel.currentVideoFilter
        )
        appModel.enqueueRemoteViewerOpen(configId: config.id)
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
