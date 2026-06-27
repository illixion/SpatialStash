/*
 Spatial Stash - Video Ornaments View

 Controls for the video player including navigation, format toggle, and back button.
 All per-window state is read from VideoWindowModel so multiple video windows are
 independent. Styled to match PhotoOrnamentView.

 Layout: [Gallery] | [< N/M >] | [ViewMode v] | [Info] | [Share] | [... More v] | [Title]
 Playback transport (play/pause, scrubber with A-B markers, A-B loop, mute)
 lives in the separate VideoControlBar overlay, not the ornament.
 The More menu holds Adjustments (opens the enhancements popover, which now
 includes Flip), Slideshow, and Pop Out (pushed only).
 */

import SwiftUI

struct VideoOrnamentsView: View {
    @Bindable var windowModel: VideoWindowModel
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// Action to show the main gallery window
    var onGalleryButtonTap: () -> Void
    /// Custom pop-out action (used by pushed windows to open a new window and dismiss self)
    var onPopOut: (() -> Void)? = nil

    @State private var showAdjustmentsPopover = false

    private var video: GalleryVideo { windowModel.video }

    var body: some View {
        HStack(spacing: 16) {
            // Gallery button
            Button(action: onGalleryButtonTap) {
                Image(systemName: "square.grid.2x2")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help(windowModel.wasPushed ? "Videos" : "Show Gallery")

            Divider()
                .frame(height: 24)

            // Previous video
            Button {
                windowModel.previousVideo()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(!windowModel.hasPreviousVideo)

            // Video counter
            Text("\(windowModel.currentVideoPosition) / \(windowModel.videoCount)")
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(minWidth: 60)

            // Next video
            Button {
                windowModel.nextVideo()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(!windowModel.hasNextVideo)

            // View mode toggle (2D/3D)
            Divider()
                .frame(height: 24)

            viewModeMenu

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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
        .onChange(of: windowModel.showMediaInfo) { _, isOpen in
            if isOpen { windowModel.cancelAutoHideTimer() }
            else { windowModel.startAutoHideTimer() }
        }
        .onChange(of: showAdjustmentsPopover) { _, isOpen in
            windowModel.showAdjustments = isOpen
            if isOpen { windowModel.cancelAutoHideTimer() }
            else { windowModel.startAutoHideTimer() }
        }
        .onChange(of: windowModel.showShareSheet) { _, isOpen in
            if isOpen { windowModel.cancelAutoHideTimer() }
            else { windowModel.startAutoHideTimer() }
        }
    }

    // MARK: - Info Button

    private var infoButton: some View {
        Button {
            windowModel.showMediaInfo.toggle()
        } label: {
            Image(systemName: video.rating100 != nil ? "info.circle.fill" : "info.circle")
                .font(.title3)
                .foregroundColor(video.rating100 != nil ? .yellow : nil)
        }
        .buttonStyle(.borderless)
        .help("Info")
        .sheet(isPresented: $windowModel.showMediaInfo) {
            MediaDetailSheet(
                mediaType: .scene(stashId: video.stashId),
                onDelete: {
                    let stashId = video.stashId
                    appModel.galleryVideos.removeAll { $0.stashId == stashId }
                    windowModel.galleryVideos.removeAll { $0.stashId == stashId }
                    dismissWindow()
                }
            )
        }
    }

    // MARK: - Share

    private var shareButton: some View {
        Button {
            Task { await windowModel.shareVideo() }
        } label: {
            Group {
                if windowModel.isPreparingShare {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(windowModel.isPreparingShare)
        .help("Share")
        .sheet(isPresented: Binding(
            get: { windowModel.shareFileURL != nil },
            set: { if !$0 { windowModel.shareFileURL = nil } }
        )) {
            windowModel.startAutoHideTimer()
        } content: {
            if let url = windowModel.shareFileURL {
                ActivityViewController(
                    activityItems: [url],
                    isPresented: Binding(
                        get: { windowModel.shareFileURL != nil },
                        set: { if !$0 { windowModel.shareFileURL = nil } }
                    )
                )
            }
        }
    }

    // MARK: - More Menu

    private var moreMenu: some View {
        Menu {
            // .onAppear/.onDisappear on the menu content pause the host's
            // auto-hide while the menu is open (same pattern as PhotoOrnamentView).
            Group {
                Button {
                    showAdjustmentsPopover.toggle()
                } label: {
                    Label("Adjustments", systemImage: "slider.horizontal.3")
                }

                Button {
                    launchVideoSlideshow()
                } label: {
                    Label("Slideshow", systemImage: "play.fill")
                }

                if windowModel.wasPushed, onPopOut != nil {
                    Divider()

                    Button {
                        onPopOut?()
                    } label: {
                        Label("Pop Out", systemImage: "rectangle.portrait.and.arrow.forward")
                    }
                }
            }
            .onAppear { chromeMenu(opened: true) }
            .onDisappear { chromeMenu(opened: false) }
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
                currentAdjustments: $windowModel.currentAdjustments,
                globalAdjustments: Binding(
                    get: { appModel.globalVisualAdjustments },
                    set: { appModel.globalVisualAdjustments = $0 }
                ),
                showAutoEnhance: false,
                showFlip: true,
                isImageFlipped: windowModel.isFlipped,
                onToggleFlip: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        windowModel.toggleFlip()
                    }
                }
            )
        }
    }

    /// Whether the More menu button should show a highlight
    private var moreMenuHighlighted: Bool {
        windowModel.effectiveVideoAdjustments.isModified || windowModel.isFlipped
    }

    private func chromeMenu(opened: Bool) {
        if opened {
            windowModel.openOrnamentMenuCount += 1
            windowModel.cancelAutoHideTimer()
        } else {
            windowModel.openOrnamentMenuCount = max(0, windowModel.openOrnamentMenuCount - 1)
            if windowModel.openOrnamentMenuCount == 0 {
                windowModel.startAutoHideTimer()
            }
        }
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
        // Run the slideshow over the same video source/filter this window is browsing.
        appModel.pendingVideoSlideshowSource = VideoSlideshowSourceOverride(
            videoSource: windowModel.videoSource,
            filter: windowModel.snapshotFilter
        )
        appModel.enqueueRemoteViewerOpen(configId: config.id)
    }

    // MARK: - View Mode Menu

    @ViewBuilder
    private var viewModeMenu: some View {
        Menu {
            Button {
                windowModel.set2DMode()
            } label: {
                HStack {
                    Text("2D")
                    if !windowModel.shouldUse3DMode {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            Button {
                Task { await windowModel.enable3DMode() }
            } label: {
                HStack {
                    Text("3D")
                    if windowModel.shouldUse3DMode {
                        Image(systemName: "checkmark")
                    }
                }
            }

            if windowModel.shouldUse3DMode {
                Divider()

                Button {
                    windowModel.showVideo3DSettingsSheet = true
                } label: {
                    Label("Edit 3D Settings", systemImage: "slider.horizontal.3")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: currentModeIcon)
                Text(currentModeLabel)
                    .font(.caption)
                if windowModel.shouldUse3DMode {
                    if let settings = windowModel.video3DSettings {
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

    private var currentModeIcon: String {
        windowModel.shouldUse3DMode ? "view.3d" : "view.2d"
    }

    private var currentModeLabel: String {
        windowModel.shouldUse3DMode ? "3D" : "2D"
    }
}
