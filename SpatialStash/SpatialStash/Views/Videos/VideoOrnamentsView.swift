/*
 Spatial Stash - Video Ornaments View

 Controls for the video player including navigation, format toggle, and back button.
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
    @State private var isUpdatingMediaInfo = false
    @State private var showAdjustmentsPopover = false

    var body: some View {
        VStack {
            HStack(spacing: 16) {
                // Gallery button (shows main window, matching photo viewer design)
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

                // View mode toggle (2D/3D for all videos)
                Divider()
                    .frame(height: 24)

                viewModeMenu(for: video)

                // Star rating / O counter popover button
                Divider()
                    .frame(height: 24)

                Button {
                    showMediaInfo.toggle()
                } label: {
                        Image(systemName: currentVideo.rating100 != nil ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundColor(currentVideo.rating100 != nil ? .yellow : nil)
                    }
                    .buttonStyle(.borderless)
                    .help("Rating & O Count")
                    .popover(isPresented: $showMediaInfo) {
                        MediaInfoPopover(
                            currentRating100: currentVideo.rating100,
                            oCounter: currentVideo.oCounter ?? 0,
                            isUpdating: isUpdatingMediaInfo,
                            onRate: { newRating in
                                let stashId = currentVideo.stashId
                                isUpdatingMediaInfo = true
                                Task {
                                    try? await appModel.updateVideoRating(stashId: stashId, rating100: newRating)
                                    isUpdatingMediaInfo = false
                                }
                            },
                            onIncrementO: {
                                let stashId = currentVideo.stashId
                                isUpdatingMediaInfo = true
                                Task {
                                    try? await appModel.incrementVideoOCounter(stashId: stashId)
                                    isUpdatingMediaInfo = false
                                }
                            },
                            onDecrementO: {
                                let stashId = currentVideo.stashId
                                isUpdatingMediaInfo = true
                                Task {
                                    try? await appModel.decrementVideoOCounter(stashId: stashId)
                                    isUpdatingMediaInfo = false
                                }
                            }
                        )
                    }

                // Share button
                Divider()
                    .frame(height: 24)

                Button {
                    // Ensure selectedVideo is set for share action
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

                // Slideshow
                Divider()
                    .frame(height: 24)

                Button {
                    launchGallerySlideshow()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Slideshow")

                // Visual adjustments
                Divider()
                    .frame(height: 24)

                Button {
                    showAdjustmentsPopover.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title3)
                        .padding(6)
                        .background(effectiveVideoAdjustments.isModified ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.borderless)
                .help("Visual Adjustments")
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

                // Flip video
                Divider()
                    .frame(height: 24)

                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        appModel.isVideoFlipped.toggle()
                    }
                } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .font(.title3)
                        .padding(6)
                        .background(appModel.isVideoFlipped ? .white.opacity(0.3) : .clear, in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.borderless)
                .help("Flip Video")

                // Pop out button (only for pushed windows, matching photo viewer pattern)
                if wasPushed {
                    Divider()
                        .frame(height: 24)

                    Button {
                        if let onPopOut {
                            onPopOut()
                        } else {
                            popOutVideo()
                        }
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.forward")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help("Pop Out")
                }

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

    @ViewBuilder
    private func viewModeMenu(for video: GalleryVideo) -> some View {
        Menu {
            // 2D Mode option
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

            // 3D Mode option
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

            // Edit 3D Settings (only show when in 3D mode)
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
                // Show format badge
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

    /// Whether the current mode is 3D (either auto-detected or forced)
    private var shouldUse3DMode: Bool {
        // Explicitly set to 2D
        if appModel.videoStereoscopicOverride == false {
            return false
        }
        // Explicitly set to 3D or has custom settings
        if appModel.videoStereoscopicOverride == true || appModel.video3DSettings != nil {
            return true
        }
        // Auto-detect from video tags
        return currentVideo.isStereoscopic
    }

    private func enable3DMode(for video: GalleryVideo) {
        Task {
            // Check for saved settings first
            if let savedSettings = await Video3DSettingsTracker.shared.loadSettings(videoId: video.stashId) {
                await MainActor.run {
                    appModel.video3DSettings = savedSettings
                    appModel.videoStereoscopicOverride = true
                }
                return
            }

            // Check for tag-detected settings
            if let tagSettings = Video3DSettings.from(video: video) {
                await MainActor.run {
                    appModel.video3DSettings = tagSettings
                    appModel.videoStereoscopicOverride = true
                }
                return
            }

            // No saved or tag settings - show settings sheet
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
