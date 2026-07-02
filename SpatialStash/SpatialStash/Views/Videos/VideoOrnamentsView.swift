/*
 Spatial Stash - Video Ornaments View

 Controls for the video player including navigation, format toggle, and back button.
 All per-window state is read from VideoWindowModel so multiple video windows are
 independent. Styled to match PhotoOrnamentView.

 Layout: [Gallery] | [< N/M >] | [ViewMode v] | [Info] | [Share] | [... More v] | [Title]
 Playback transport (play/pause, scrubber with A-B markers, A-B loop, mute)
 lives in the separate VideoControlBar overlay — except in fake-3D, where
 showTransport folds it in as a second ornament row so all chrome is coplanar.
 The More menu holds Adjustments (opens the standalone video-adjustments window,
 which hosts Flip + the fake-3D stereo sliders), Slideshow, and Pop Out (pushed only).
 */

import SwiftUI

struct VideoOrnamentsView: View {
    @Bindable var windowModel: VideoWindowModel
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var depthModels = DepthModelManager.shared

    /// When true, stack the playback transport (VideoControlBar) above the button
    /// row as a second ornament row. Used by fake-3D, where the video lives in a
    /// RealityView volume and a separate 2D control-bar overlay floats at a
    /// different depth than the video. Folding it into the ornament keeps all
    /// chrome on one plane.
    var showTransport: Bool = false
    /// Action to show the main gallery window
    var onGalleryButtonTap: () -> Void
    /// Custom pop-out action (used by pushed windows to open a new window and dismiss self)
    var onPopOut: (() -> Void)? = nil

    private var video: GalleryVideo { windowModel.video }

    var body: some View {
        if showTransport {
            VStack(spacing: 12) {
                VideoControlBar(windowModel: windowModel)
                buttonRow
            }
        } else {
            buttonRow
        }
    }

    private var buttonRow: some View {
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

            // Depth-conversion status for THIS video — visible at a glance
            // without keeping the ViewMode menu open.
            if let phase = DepthConversionManager.shared.phase(for: video.stashId) {
                Divider()
                    .frame(height: 24)
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(phase.label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            } else if DepthConversionManager.shared.isProcessing(videoIdentity: video.stashId) {
                Divider()
                    .frame(height: 24)
                Text("Conversion queued")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
        .onChange(of: windowModel.showMediaInfo) { _, isOpen in
            if isOpen { windowModel.cancelAutoHideTimer() }
            else { windowModel.startAutoHideTimer() }
        }
        .onChange(of: windowModel.showAdjustments) { _, isOpen in
            // Adjustments now presents as a side ornament (VideoWindowView), so
            // it never overlaps the video; just pause auto-hide while it's open.
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
                },
                onSaved: { newRating in
                    let stashId = video.stashId
                    windowModel.video.rating100 = newRating
                    if let idx = windowModel.galleryVideos.firstIndex(where: { $0.stashId == stashId }) {
                        windowModel.galleryVideos[idx].rating100 = newRating
                    }
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
                    // Open the standalone Adjustments window (repositionable,
                    // never overlaps the video). showAdjustments pauses auto-hide.
                    appModel.videoAdjustmentsTarget = windowModel
                    windowModel.showAdjustments = true
                    openWindow(id: "video-adjustments")
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
            // Pause auto-hide + flag chrome open (recedes fake-3D so this menu
            // isn't occluded), same pattern as the More menu.
            Group {
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

            // Fake-3D conversion of a mono video: realtime inference or
            // pre-processed cached depth. Only for AVFoundation-decodable sources.
            Divider()

            Button {
                if windowModel.shouldUsePseudo3D {
                    windowModel.disablePseudo3D()
                } else {
                    windowModel.requestPseudo3D()
                }
            } label: {
                HStack {
                    Text("Convert to 3D (Beta)")
                    if windowModel.shouldUsePseudo3D {
                        Image(systemName: "checkmark")
                    }
                }
            }
            .disabled(windowModel.playbackRenderer != .nativeMetal)

            // Background depth conversion for THIS video: live progress + cancel.
            if let phase = DepthConversionManager.shared.phase(for: video.stashId) {
                Text(phase.label)
                Button(role: .destructive) {
                    DepthConversionManager.shared.cancel(videoIdentity: video.stashId)
                } label: {
                    Label("Cancel Conversion", systemImage: "xmark.circle")
                }
            } else if DepthConversionManager.shared.isProcessing(videoIdentity: video.stashId) {
                Text("Conversion queued")
                Button(role: .destructive) {
                    DepthConversionManager.shared.cancel(videoIdentity: video.stashId)
                } label: {
                    Label("Cancel Conversion", systemImage: "xmark.circle")
                }
            }

            if windowModel.shouldUsePseudo3D {
                Menu("3D Depth") {
                    depthButton("Subtle", .subtle)
                    depthButton("Medium", .medium)
                    depthButton("Strong", .strong)
                }

                // Switch the monocular depth model, or download a missing one
                // (higher quality than the built-in heuristic). Applies on the
                // next fake-3D video opened.
                depthModelMenu
            }
            }
            .onAppear { chromeMenu(opened: true) }
            .onDisappear { chromeMenu(opened: false) }
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

    @ViewBuilder
    private func depthButton(_ title: String, _ preset: Pseudo3DSettings) -> some View {
        Button {
            // Mutate rather than replace so toggles (autoConvergence) survive.
            windowModel.pseudo3DSettings.depthStrength = preset.depthStrength
            windowModel.pseudo3DSettings.convergence = preset.convergence
        } label: {
            HStack {
                Text(title)
                if windowModel.pseudo3DSettings.depthStrength == preset.depthStrength {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    /// Effective real-time model shown as selected: the explicit preference if
    /// it's installed, otherwise the first installed model (what findModelURL
    /// loads).
    private var effectiveDepthModelName: String {
        let pref = appModel.realtimeDepthModelName
        if !pref.isEmpty, depthModels.installedNames.contains(pref) { return pref }
        return depthModels.installedNames.first ?? ""
    }

    /// Depth-model submenu: pick among installed models, and download any offered
    /// variant that isn't installed yet. Switches the REAL-TIME model — that's
    /// what live-reloads the playing video; the pre-process model is picked in
    /// Settings → Display. (Only shown while fake-3D is active, which already
    /// requires an installed model — so there's no heuristic entry.)
    @ViewBuilder
    private var depthModelMenu: some View {
        Menu("Depth Model (Real-Time)") {
            ForEach(depthModels.installedNames, id: \.self) { name in
                Button {
                    appModel.realtimeDepthModelName = name
                } label: {
                    HStack {
                        Text(DepthModelManager.displayName(for: name))
                        if effectiveDepthModelName == name {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            let downloadable = DepthModelManager.variants.filter { !depthModels.isInstalled($0) }
            if !downloadable.isEmpty {
                Divider()
                ForEach(downloadable) { variant in
                    Button {
                        Task { await depthModels.download(variant) }
                    } label: {
                        Label(
                            depthModels.isDownloading(variant)
                                ? "Downloading \(variant.displayName)…"
                                : "Download \(variant.displayName)",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(depthModels.isDownloading(variant))
                }
            }
        }
    }

    private var currentModeIcon: String {
        (windowModel.shouldUse3DMode || windowModel.shouldUsePseudo3D) ? "view.3d" : "view.2d"
    }

    private var currentModeLabel: String {
        if windowModel.shouldUsePseudo3D { return "3D*" }
        return windowModel.shouldUse3DMode ? "3D" : "2D"
    }
}
