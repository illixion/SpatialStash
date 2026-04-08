/*
 Spatial Stash - Remote Viewer Window View

 Main viewer window that displays a slideshow of images from the
 remote API with clock, sensor overlays, Ken Burns animation,
 and ornament controls.
 */

import Combine
import os
import SwiftUI

struct RemoteViewerWindowView: View {
    let windowValue: RemoteViewerWindowValue
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var viewerModel: RemoteViewerModel?
    @State private var showHomeAssistant = false
    @State private var showHistory = false
    @State private var windowSize: CGSize = .zero
    @State private var currentTime = Date()
    @State private var autoHideTimer: Task<Void, Never>?
    @State private var controlsVisible = true

    // Ken Burns animation state
    @State private var kenBurnsScale: CGFloat = 1.0
    @State private var kenBurnsOffset: CGSize = .zero

    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background
                if !(viewerModel?.config.transparentBackground ?? false) {
                    Color.black.ignoresSafeArea()
                }

                // Image layers
                if let model = viewerModel {
                    imageLayer(model: model)
                        .brightness(model.effectiveBrightness)
                        .contrast(model.effectiveContrast)
                        .saturation(model.effectiveSaturation)
                        .opacity(model.effectiveOpacity)
                }

                // Clock overlay
                if let model = viewerModel, model.showClock {
                    clockOverlay(model: model)
                }

                // Sensor overlay
                if let model = viewerModel, model.showSensors, !model.sortedSensors.isEmpty {
                    sensorOverlay(model: model)
                }

                // Loading indicator
                if viewerModel?.isLoading == true && viewerModel?.currentImage == nil {
                    ProgressView()
                        .scaleEffect(2)
                }

                // Toast notification
                if let model = viewerModel, let toast = model.toastMessage {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(toast)
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(model.toastIsError ? Color.red.opacity(0.85) : Color.black.opacity(0.7))
                                )
                            Spacer()
                        }
                        .padding(.bottom, 80)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut, value: model.toastMessage)
                }

                // Home Assistant WebView overlay
                if showHomeAssistant, let url = homeAssistantURL {
                    HomeAssistantWebView(url: url)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                // History overlay
                if showHistory, let model = viewerModel {
                    RemoteHistoryView(
                        history: model.postHistory,
                        imageURLs: model.historyImageURLs
                    )
                    .transition(.opacity)
                }
            }
            .onAppear {
                windowSize = geo.size
            }
            .onChange(of: geo.size) { _, newSize in
                windowSize = newSize
                viewerModel?.updateWindowAspectRatio(newSize)
            }
        }
        .ornament(
            visibility: controlsVisible ? .visible : .hidden,
            attachmentAnchor: .scene(.bottomFront),
            ornament: {
                if let model = viewerModel {
                    RemoteViewerOrnamentView(
                        model: model,
                        showHomeAssistant: $showHomeAssistant,
                        showHistory: $showHistory
                    )
                }
            }
        )
        .onAppear {
            setupModel()
            resetAutoHideTimer()
        }
        .onDisappear {
            viewerModel?.stop()
            autoHideTimer?.cancel()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            viewerModel?.handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
        .onReceive(clockTimer) { time in
            currentTime = time
        }
        .onChange(of: appModel.globalVisualAdjustments) { _, newValue in
            viewerModel?.globalAdjustments = newValue
        }
        .onChange(of: viewerModel?.showAdjustmentsPopover) { _, isOpen in
            if isOpen == true {
                autoHideTimer?.cancel()
            } else {
                resetAutoHideTimer()
            }
        }
        .onTapGesture {
            controlsVisible = true
            resetAutoHideTimer()
        }
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
    }

    @ViewBuilder
    private func imageLayer(model: RemoteViewerModel) -> some View {
        ZStack {
            // Current image
            if let image = model.currentImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(model.config.enableKenBurns ? kenBurnsScale : 1.0)
                    .offset(model.config.enableKenBurns ? kenBurnsOffset : .zero)
                    .opacity(model.isTransitioning ? 0 : 1)
                    .clipped()
            }

            // Next image (fading in during transition)
            if let image = model.nextImage, model.isTransitioning {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(1)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.currentPost?.id) { _, _ in
            startKenBurnsAnimation(model: model)
        }
    }

    @ViewBuilder
    private func clockOverlay(model: RemoteViewerModel) -> some View {
        let scale = model.config.textSize

        VStack {
            Spacer()
            HStack {
                // Clock (bottom-left)
                VStack(alignment: .leading, spacing: 4) {
                    Text(timeString)
                        .font(.system(size: 48 * scale, weight: .light, design: .monospaced))
                    Text(dateString)
                        .font(.system(size: 20 * scale, weight: .regular))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.7))
                )
                .padding(16)

                Spacer()
            }
        }
    }

    @ViewBuilder
    private func sensorOverlay(model: RemoteViewerModel) -> some View {
        let scale = model.config.textSize

        VStack {
            HStack {
                Spacer()
                // Sensors (top-right)
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(model.sortedSensors) { sensor in
                        HStack(spacing: 4) {
                            if sensor.isUnavailable {
                                Text("\u{2757}")
                            }
                            Text(sensor.displayEmoji)
                            Text(sensor.friendlyName + ":")
                            Text(sensor.isUnavailable ? (sensor.lastKnownState ?? "N/A") : sensor.state)
                            if !sensor.unitOfMeasurement.isEmpty {
                                Text(sensor.unitOfMeasurement)
                            }
                        }
                        .font(.system(size: 16 * scale))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.7))
                )
                .padding(16)
            }
            Spacer()
        }
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: currentTime)
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: currentTime)
    }

    private var homeAssistantURL: URL? {
        guard let model = viewerModel,
              !model.config.homeAssistantURL.isEmpty else { return nil }
        return URL(string: model.config.homeAssistantURL)
    }

    private func setupModel() {
        guard viewerModel == nil else { return }

        // Look up config from saved configs or the gallery slideshow config
        let config: RemoteViewerConfig
        if let saved = appModel.savedRemoteConfigs.first(where: { $0.id == windowValue.configId }) {
            config = saved
        } else if let gallery = appModel.gallerySlideshowConfig, gallery.id == windowValue.configId {
            config = gallery
        } else {
            AppLogger.remoteViewer.error("No config found for id \(windowValue.configId.uuidString, privacy: .public)")
            return
        }

        let model = RemoteViewerModel(config: config)
        model.globalAdjustments = appModel.globalVisualAdjustments
        model.maxImageResolution = appModel.maxImageResolution
        model.updateWindowAspectRatio(windowSize)

        // Gallery mode: use the app's image source instead of remote API
        if config.apiEndpoint.isEmpty {
            model.galleryImageSource = appModel.imageSource
        }

        // Wire up window callbacks
        model.onOpenVideoWindow = { [openWindow] url in
            openWindow(id: "remote-video", value: RemoteVideoWindowValue(videoURL: url))
        }
        model.onDismissVideoWindow = { [dismissWindow] in
            dismissWindow(id: "remote-video")
        }
        model.onOpenAlertWindow = { [openWindow] text, bgColor, imageUrl in
            openWindow(id: "remote-alert", value: RemoteAlertWindowValue(text: text, bgColorHex: bgColor, imageUrl: imageUrl))
        }
        model.onDismissAlertWindow = { [dismissWindow] in
            dismissWindow(id: "remote-alert")
        }

        model.onConfigChanged = { [appModel] updatedConfig in
            appModel.saveRemoteConfig(updatedConfig)
        }

        self.viewerModel = model
        model.start()
    }

    private func startKenBurnsAnimation(model: RemoteViewerModel) {
        guard model.config.enableKenBurns else { return }

        // Instantly snap to 1.0 without animating the zoom-out
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            kenBurnsScale = 1.0
            kenBurnsOffset = .zero
        }

        // Then animate the zoom-in to the focus point
        let focus = model.focusPoint
        let targetScale: CGFloat = 1.3
        let offsetX = (focus.x - 0.5) * windowSize.width * 0.15
        let offsetY = (focus.y - 0.5) * windowSize.height * 0.15

        withAnimation(.easeInOut(duration: model.config.delay)) {
            kenBurnsScale = targetScale
            kenBurnsOffset = CGSize(width: -offsetX, height: -offsetY)
        }
    }

    private func resetAutoHideTimer() {
        autoHideTimer?.cancel()
        guard appModel.autoHideDelay > 0 else { return }
        autoHideTimer = Task {
            try? await Task.sleep(for: .seconds(appModel.autoHideDelay))
            guard !Task.isCancelled else { return }
            withAnimation { controlsVisible = false }
        }
    }
}
