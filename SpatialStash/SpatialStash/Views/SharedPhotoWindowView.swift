/*
 Spatial Stash - Shared Photo Window View

 Pop-out viewer for images received via the system share sheet.
 Reuses PhotoWindowModel for RealityKit rendering and 3D conversion.
 Includes a Save button to persist the image to Documents/Photos/.
 */

import os
import RealityKit
import SwiftUI
import UIKit

struct SharedPhotoWindowView: View {
    let item: SharedMediaItem
    @State private var windowModel: PhotoWindowModel
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?

    @State private var viewerWindowSize: CGSize?
    @State private var isSaving = false
    @State private var isSaved = false
    @State private var saveError: String?

    private var currentBounds: CGSize {
        viewerWindowSize ?? appModel.mainWindowSize
    }

    init(item: SharedMediaItem, appModel: AppModel) {
        self.item = item
        _windowModel = State(initialValue: PhotoWindowModel(image: item.asGalleryImage(), appModel: appModel))
    }

    var body: some View {
        Group {
            if FileManager.default.fileExists(atPath: item.cachedFileURL.path) {
                imageContent
            } else {
                unavailableContent
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { viewerWindowSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in viewerWindowSize = newSize }
            }
        )
        .ornament(
            visibility: windowModel.isUIHidden ? .hidden : .visible,
            attachmentAnchor: .scene(.bottomFront),
            ornament: {
                SharedPhotoOrnament(
                    windowModel: windowModel,
                    isSaving: isSaving,
                    isSaved: isSaved,
                    saveError: saveError,
                    onSave: savePhoto
                )
            }
        )
        .onAppear {
            windowModel.startAutoHideTimer()
        }
        .onDisappear {
            windowModel.cleanup()
            resetWindowRestrictions()
            Task {
                await SharedMediaCache.shared.removeCachedFile(for: item.id)
            }
        }
        .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
            if wasLoading && !isLoading {
                windowModel.isUIHidden = false
                windowModel.startAutoHideTimer()
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        ZStack {
            if windowModel.isAnimatedGIF, let gifData = windowModel.currentImageData {
                AnimatedGIFDetailView(imageData: gifData)
                    .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
                    .contentShape(.rect)
                    .onTapGesture {
                        windowModel.toggleUIVisibility()
                    }
                    .onAppear {
                        resizeGIFWindowToFit(windowModel.imageAspectRatio, within: appModel.mainWindowSize)
                    }
                    .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                        resizeGIFWindowToFit(newAspectRatio, within: currentBounds)
                    }
                    .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                        if wasLoading && !isLoading {
                            resizeGIFWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                        }
                    }
            } else {
                GeometryReader3D { geometry in
                    RealityView { content in
                        await windowModel.createImagePresentationComponent()
                        let availableBounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                        scaleImagePresentationToFit(in: availableBounds)
                        content.add(windowModel.contentEntity)
                        windowModel.ensureInputPlaneReady()
                        updateInputPlane(in: availableBounds)
                        if windowModel.inputPlaneEntity.parent == nil {
                            content.add(windowModel.inputPlaneEntity)
                        }
                        resizeWindowToFit(windowModel.imageAspectRatio, within: appModel.mainWindowSize)
                        await windowModel.autoGenerateSpatial3DIfNeeded()
                    } update: { content in
                        guard let presentationScreenSize = windowModel
                            .contentEntity
                            .observable
                            .components[ImagePresentationComponent.self]?
                            .presentationScreenSize, presentationScreenSize != .zero else {
                                return
                        }
                        let originalPosition = windowModel.contentEntity.position(relativeTo: nil)
                        windowModel.contentEntity.setPosition(SIMD3<Float>(originalPosition.x, originalPosition.y, 0.0), relativeTo: nil)
                        let availableBounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
                        scaleImagePresentationToFit(in: availableBounds)
                        windowModel.ensureInputPlaneReady()
                        updateInputPlane(in: availableBounds)
                        if windowModel.inputPlaneEntity.parent == nil {
                            content.add(windowModel.inputPlaneEntity)
                        }
                    }
                    .onAppear {
                        guard let windowScene = resolvedWindowScene else { return }
                        windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .uniform))
                    }
                    .onChange(of: windowModel.imageAspectRatio) { _, newAspectRatio in
                        resizeWindowToFit(newAspectRatio, within: currentBounds)
                    }
                    .onChange(of: windowModel.isLoadingDetailImage) { wasLoading, isLoading in
                        if wasLoading && !isLoading {
                            resizeWindowToFit(windowModel.imageAspectRatio, within: currentBounds)
                        }
                    }
                    .gesture(
                        TapGesture()
                            .targetedToAnyEntity()
                            .onEnded { _ in
                                windowModel.toggleUIVisibility()
                            }
                    )
                }
                .aspectRatio(windowModel.imageAspectRatio, contentMode: .fit)
            }
        }
    }

    private var unavailableContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("Shared photo is no longer available")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("The temporary cache was cleared.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Save

    private func savePhoto() {
        guard !isSaving && !isSaved else { return }
        isSaving = true
        saveError = nil

        Task {
            do {
                _ = try SharedMediaSaver.saveImage(
                    from: item.cachedFileURL,
                    originalFileName: item.originalFileName
                )
                isSaved = true
            } catch {
                saveError = error.localizedDescription
                AppLogger.sharedMedia.error("Failed to save shared photo: \(error.localizedDescription, privacy: .public)")
            }
            isSaving = false
        }
    }

    // MARK: - Window Sizing (mirrored from PhotoWindowView)

    private func resizeWindowToFit(_ aspectRatio: CGFloat, within bounds: CGSize) {
        guard let windowScene = resolvedWindowScene else { return }
        let boundsAR = bounds.width / bounds.height
        let size: CGSize
        if aspectRatio > boundsAR {
            size = CGSize(width: bounds.width, height: bounds.width / aspectRatio)
        } else {
            size = CGSize(width: bounds.height * aspectRatio, height: bounds.height)
        }
        UIView.performWithoutAnimation {
            windowScene.requestGeometryUpdate(.Vision(size: size))
        }
    }

    private func resizeGIFWindowToFit(_ aspectRatio: CGFloat, within bounds: CGSize) {
        guard let windowScene = resolvedWindowScene else { return }
        let boundsAR = bounds.width / bounds.height
        let size: CGSize
        if aspectRatio > boundsAR {
            size = CGSize(width: bounds.width, height: bounds.width / aspectRatio)
        } else {
            size = CGSize(width: bounds.height * aspectRatio, height: bounds.height)
        }
        UIView.performWithoutAnimation {
            windowScene.requestGeometryUpdate(.Vision(size: size, resizingRestrictions: .uniform))
        }
    }

    private func resetWindowRestrictions() {
        guard let windowScene = resolvedWindowScene else { return }
        windowScene.requestGeometryUpdate(.Vision(resizingRestrictions: .freeform))
    }

    func scaleImagePresentationToFit(in boundsInMeters: BoundingBox) {
        guard let imagePresentationComponent = windowModel.contentEntity.components[ImagePresentationComponent.self] else {
            return
        }
        let presentationScreenSize = imagePresentationComponent.presentationScreenSize
        let scale = min(
            boundsInMeters.extents.x / presentationScreenSize.x,
            boundsInMeters.extents.y / presentationScreenSize.y
        )
        windowModel.contentEntity.scale = SIMD3<Float>(scale, scale, 1.0)
    }

    func updateInputPlane(in boundsInMeters: BoundingBox) {
        let scale = SIMD3<Float>(boundsInMeters.extents.x, boundsInMeters.extents.y, 1.0)
        windowModel.inputPlaneEntity.scale = scale
        let center = boundsInMeters.center
        windowModel.inputPlaneEntity.setPosition(
            SIMD3<Float>(center.x, center.y, 0.01),
            relativeTo: nil
        )
    }

    private var resolvedWindowScene: UIWindowScene? {
        if let sceneDelegate {
            return sceneDelegate.windowScene
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

// MARK: - Ornament

struct SharedPhotoOrnament: View {
    @Bindable var windowModel: PhotoWindowModel
    @Environment(\.openWindow) private var openWindow

    let isSaving: Bool
    let isSaved: Bool
    let saveError: String?
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Show main gallery window
            Button {
                openWindow(id: "main")
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Show Gallery")

            Divider()
                .frame(height: 24)

            // Generate/Toggle 3D button
            Button {
                Task {
                    if windowModel.spatial3DImageState == .notGenerated {
                        await windowModel.generateSpatial3DImage()
                    } else {
                        windowModel.toggleSpatial3DView()
                    }
                }
            } label: {
                Group {
                    if windowModel.spatial3DImageState == .generating {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: windowModel.spatial3DImageState == .generated ? "view.3d" : "wand.and.stars")
                    }
                }
                .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(windowModel.spatial3DImageState == .generating || windowModel.isAnimatedGIF)
            .help(windowModel.spatial3DImageState == .notGenerated ? "Generate 3D" :
                  windowModel.spatial3DImageState == .generating ? "Generating..." : "Toggle 3D")

            Divider()
                .frame(height: 24)

            // Save button
            Button(action: onSave) {
                Group {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if isSaved {
                        Image(systemName: "checkmark")
                    } else if saveError != nil {
                        Image(systemName: "exclamationmark.triangle")
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(isSaving || isSaved)
            .help(isSaved ? "Saved" : saveError ?? "Save to Files")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }
}
