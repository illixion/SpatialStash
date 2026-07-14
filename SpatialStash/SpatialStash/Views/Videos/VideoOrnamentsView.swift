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
    @Environment(\.openURL) private var openURL
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
            // without keeping the ViewMode menu open. Isolated in its own view
            // so its continuous observation of DepthConversionManager doesn't
            // re-run THIS body (which holds the Menu) — a parent that observes
            // the manager recreates the Menu ~30-60×/sec, refreshing the open
            // dropdown and dropping taps.
            ConversionStatusRow(videoStashId: video.stashId)
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

                // Last-resort fallback for a web-sourced stream the in-app
                // players (native + WebKit) can't decode — open it in Safari.
                if isRemoteStream {
                    Divider()

                    Button {
                        openURL(windowModel.video.streamURL)
                    } label: {
                        Label("Open in Safari", systemImage: "safari")
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

    /// Whether this window is playing a remote http(s) stream (vs a local file).
    private var isRemoteStream: Bool {
        let scheme = windowModel.video.streamURL.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
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
            // The three modes behave like a radio group: exactly one carries
            // the checkmark, selecting another switches directly (each engage
            // path turns the other modes off), and re-selecting the active
            // one is a no-op — leaving a mode means picking a different one.
            modeButton("2D", mode: .flat) {
                windowModel.set2DMode()
            }

            Divider()

            modeButton("3D", mode: .stereoscopic) {
                Task { await windowModel.enable3DMode() }
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

            modeButton("Convert to 3D (Beta)", mode: .pseudo3D) {
                windowModel.requestPseudo3D()
            }
            .disabled(windowModel.playbackRenderer != .nativeMetal)

            // Background depth conversion for THIS video: status + cancel.
            // Isolated in its own view so its observation of the (continuously
            // updating) DepthConversionManager doesn't re-run this menu's body
            // — that recreates the whole Menu and makes the open dropdown drop
            // taps. The subview shows the phase *kind* only (no live %) so even
            // its own updates don't reflow the menu items.
            ConversionMenuStatus(videoStashId: video.stashId)

            if windowModel.shouldUsePseudo3D {
                Menu("3D Depth") {
                    depthButton("Subtle", .subtle)
                    depthButton("Medium", .medium)
                    depthButton("Strong", .strong)
                }
            }

            // Depth-model pickers, one per pipeline, shown whenever fake-3D
            // is available. Real-Time live-reloads a playing fake-3D video;
            // Pre-Process picks the model future conversions (and the engage
            // flow's cache lookup) use — changing it here means the next
            // Convert to 3D offers a fresh conversion with that model.
            if windowModel.playbackRenderer == .nativeMetal {
                depthModelMenu(
                    "Depth Model (Real-Time)",
                    preference: appModel.realtimeDepthModelName
                ) { appModel.realtimeDepthModelName = $0 }
                depthModelMenu(
                    "Depth Model (Pre-Process)",
                    preference: appModel.preprocessDepthModelName
                ) { appModel.preprocessDepthModelName = $0 }
            }
            }
            .onAppear { chromeMenu(opened: true) }
            .onDisappear { chromeMenu(opened: false) }
        } label: {
            // Icon-only, .title3 — matches PhotoOrnamentView's 3D menu button
            // (which shows `view.3d` in the flat state). The active-mode
            // background is the only highlight.
            Image(systemName: viewModeIcon)
                .font(.title3)
                .padding(6)
                .background(
                    (windowModel.shouldUse3DMode || windowModel.shouldUsePseudo3D)
                        ? .white.opacity(0.3) : .clear,
                    in: .rect(cornerRadius: 8)
                )
        }
        // Match the other borderless ornament buttons: the default Menu style
        // renders a raised glass capsule that reads as "always highlighted"
        // (with a tiny disclosure glyph) even in 2D. Borderless keeps it flat,
        // so the only highlight comes from the active-mode background above.
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .help("View Mode")
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

    /// The three window viewing modes, mutually exclusive by construction
    /// (shouldUsePseudo3D already excludes shouldUse3DMode).
    private enum ViewMode {
        case flat, stereoscopic, pseudo3D
    }

    private var currentViewMode: ViewMode {
        if windowModel.shouldUse3DMode { return .stereoscopic }
        if windowModel.shouldUsePseudo3D { return .pseudo3D }
        return .flat
    }

    /// Radio-style mode item: checkmark on the active mode only; selecting
    /// the already-active mode does nothing.
    private func modeButton(_ title: String, mode: ViewMode, action: @escaping () -> Void) -> some View {
        Button {
            guard currentViewMode != mode else { return }
            action()
        } label: {
            HStack {
                Text(title)
                if currentViewMode == mode {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    /// Effective model shown as selected for a role: the explicit preference
    /// if it's installed, otherwise the first installed model (what
    /// findModelURL loads).
    private func effectiveDepthModelName(preference: String) -> String {
        if !preference.isEmpty, depthModels.installedNames.contains(preference) { return preference }
        return depthModels.installedNames.first ?? ""
    }

    /// Depth-model submenu for one role: pick among installed models, and
    /// download any offered variant that isn't installed yet.
    @ViewBuilder
    private func depthModelMenu(
        _ title: String,
        preference: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        Menu(title) {
            ForEach(depthModels.installedNames, id: \.self) { name in
                Button {
                    onSelect(name)
                } label: {
                    HStack {
                        Text(DepthModelManager.displayName(for: name))
                        if effectiveDepthModelName(preference: preference) == name {
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

    /// SF Symbol for the ViewMode button, mirroring PhotoOrnamentView's
    /// mapping: immersive/stereoscopic → `inset.filled.pano`, windowed fake-3D
    /// → `spatial.capture.fill`, flat → `view.3d` (the "switch to 3D"
    /// affordance, same as pictures in 2D).
    private var viewModeIcon: String {
        if windowModel.shouldUse3DMode { return "inset.filled.pano" }
        if windowModel.shouldUsePseudo3D { return "spatial.capture.fill" }
        return "view.3d"
    }
}

/// Ornament-row depth-conversion status (spinner + live label). Kept in its own
/// view so that observing the continuously-updating DepthConversionManager
/// invalidates only this small view, not the parent ornament that holds the
/// ViewMode Menu (a parent that re-renders recreates the Menu and drops taps on
/// the open dropdown).
private struct ConversionStatusRow: View {
    let videoStashId: String
    @State private var conversions = DepthConversionManager.shared

    var body: some View {
        if let phase = conversions.phase(for: videoStashId) {
            Divider()
                .frame(height: 24)
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(phase.label)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        } else if conversions.isProcessing(videoIdentity: videoStashId) {
            Divider()
                .frame(height: 24)
            Text("Conversion queued")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// In-menu depth-conversion status + cancel, isolated for the same reason as
/// ConversionStatusRow. Shows the phase *kind* only (no live percentage) so its
/// own updates never reflow the surrounding menu items.
private struct ConversionMenuStatus: View {
    let videoStashId: String
    @State private var conversions = DepthConversionManager.shared

    private var statusLabel: String? {
        if let phase = conversions.phase(for: videoStashId) {
            switch phase {
            case .downloading: return "Downloading…"
            case .converting: return "Converting to 3D…"
            case .refining: return "Refining 3D…"
            }
        }
        if conversions.isProcessing(videoIdentity: videoStashId) {
            return "Conversion queued"
        }
        return nil
    }

    var body: some View {
        if let statusLabel {
            Text(statusLabel)
            Button(role: .destructive) {
                conversions.cancel(videoIdentity: videoStashId)
            } label: {
                Label("Cancel Conversion", systemImage: "xmark.circle")
            }
        }
    }
}
