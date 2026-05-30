/*
 Spatial Stash - Quick Look 3D Preview

 Tap-and-hold "Quick Look" preview presented over the gallery grid.
 The source cell's frame is matched via `matchedGeometryEffect` so the
 preview scales out of the cell (and animates back into it on
 dismiss), mirroring iOS 3D Touch's photo pop. A side context menu
 next to the preview offers a "View in 3D" toggle that triggers the
 RealityKit 2D→3D conversion in the same view — the preview opens in
 2D so we don't pay the depth-map cost unless the user asks for it,
 which also matches iOS Quick Look's progressive-reveal feel.

 Z-stacking: an `.offset(z:)` lifts both the preview and the side
 menu well in front of diorama-thumbnail foreground layers (which
 sit at z: 24 inside the grid) so the popped-out preview can't be
 visually intersected by a thumbnail's diorama pop.

 Reduce-motion: when on, the host grid passes a `nil` namespace and
 `useMatchedGeometry: false`, so the pop animation is replaced with
 a plain opacity fade.

 Only one preview is alive at a time — RealityKit enforces a hard
 cap on concurrent ImagePresentationComponent instances on visionOS.
 */

import os
import RealityKit
import SwiftUI
import UIKit

/// Z-offset applied to the preview and side menu so they sit clearly
/// in front of any diorama-thumbnail foreground layers (z: 24) in
/// the underlying grid.
private let quickLookZOffset: CGFloat = 80

struct QuickLook3DView: View {
    @Environment(AppModel.self) private var appModel
    let image: GalleryImage
    let namespace: Namespace.ID?
    let useMatchedGeometry: Bool
    let onDismiss: () -> Void

    @State private var entity = Entity()
    @State private var aspectRatio: CGFloat = 1
    @State private var spatialReady = false
    @State private var spatialRequested = false
    @State private var spatialLoading = false
    @State private var spatialFailed = false
    @State private var loadFailed = false
    @State private var loadedImage: UIImage?
    @State private var localURL: URL?

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            GeometryReader { geo in
                // Reserve space for the side menu next to the preview.
                let menuReserve: CGFloat = 260
                let maxW = max(geo.size.width * 0.92 - menuReserve, 200)
                let maxH = geo.size.height * 0.92
                let fitted = fittedSize(in: CGSize(width: maxW, height: maxH))

                HStack(alignment: .center, spacing: 24) {
                    previewContent(size: fitted)
                    sideMenu
                        .frame(width: 220)
                        .offset(z: quickLookZOffset)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            }
        }
        .task(id: image.id) {
            await loadBase()
        }
        .onChange(of: spatialRequested) { _, requested in
            guard requested else { return }
            Task { await loadSpatial() }
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private func previewContent(size: CGSize) -> some View {
        ZStack {
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Color.secondary.opacity(0.2)
            }

            if spatialReady {
                GeometryReader3D { geometry3D in
                    RealityView { content in
                        content.add(entity)
                        scaleEntityToFit(content: content, geometry: geometry3D)
                    } update: { content in
                        scaleEntityToFit(content: content, geometry: geometry3D)
                    }
                }
                .transition(.opacity)
            }

            if (loadedImage == nil && !loadFailed) || spatialLoading {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .frame(width: size.width, height: size.height)
        .cornerRadius(20)
        .matchedGeometryEffectIfActive(
            id: image.id,
            namespace: namespace,
            active: useMatchedGeometry
        )
        .offset(z: quickLookZOffset)
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if abs(value.translation.height) > 60 || abs(value.translation.width) > 60 {
                        onDismiss()
                    }
                }
        )
    }

    // MARK: - Side menu

    private var sideMenu: some View {
        VStack(spacing: 0) {
            menuButton(
                title: spatialReady ? "Spatial 3D" : (spatialLoading ? "Generating…" : "View in 3D"),
                systemImage: "cube",
                tinted: spatialReady,
                disabled: spatialLoading || spatialReady || spatialFailed
            ) {
                spatialRequested = true
            }

            Divider().opacity(0.3)

            menuButton(
                title: "Close",
                systemImage: "xmark",
                tinted: false,
                disabled: false
            ) {
                onDismiss()
            }
        }
        .padding(.vertical, 6)
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private func menuButton(title: String, systemImage: String, tinted: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(tinted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .disabled(disabled)
    }

    // MARK: - Geometry

    private func fittedSize(in container: CGSize) -> CGSize {
        let ratio = max(aspectRatio, 0.0001)
        let containerRatio = container.width / container.height
        if ratio >= containerRatio {
            return CGSize(width: container.width, height: container.width / ratio)
        } else {
            return CGSize(width: container.height * ratio, height: container.height)
        }
    }

    private func scaleEntityToFit(content: RealityViewContent, geometry: GeometryProxy3D) {
        guard let ipc = entity.components[ImagePresentationComponent.self] else { return }
        let presentation = ipc.presentationScreenSize
        guard presentation.x > 0, presentation.y > 0 else { return }
        let bounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
        let scale = min(
            bounds.extents.x / presentation.x,
            bounds.extents.y / presentation.y
        )
        entity.scale = SIMD3<Float>(scale, scale, 1.0)
    }

    // MARK: - Loading

    /// First-stage load: resolve the source to a local file and show
    /// the 2D image immediately. No depth-map work runs here — that
    /// only happens when the user picks "View in 3D" from the side
    /// menu.
    @MainActor
    private func loadBase() async {
        spatialReady = false
        spatialRequested = false
        spatialLoading = false
        spatialFailed = false
        loadFailed = false
        loadedImage = nil
        localURL = nil

        let sourceURL = image.fullSizeURL

        let resolved: URL
        if sourceURL.isFileURL {
            resolved = sourceURL
        } else if let cached = await DiskImageCache.shared.cachedFileURL(for: sourceURL) {
            resolved = cached
        } else {
            do {
                guard let data = try await ImageLoader.shared.loadRawData(from: sourceURL) else {
                    loadFailed = true; return
                }
                await DiskImageCache.shared.saveData(data, for: sourceURL)
                guard let cached = await DiskImageCache.shared.cachedFileURL(for: sourceURL) else {
                    loadFailed = true; return
                }
                resolved = cached
            } catch {
                AppLogger.views.warning("QuickLook3DView: download failed: \(error.localizedDescription, privacy: .public)")
                loadFailed = true
                return
            }
        }

        if Task.isCancelled { return }
        localURL = resolved

        if let preview = UIImage(contentsOfFile: resolved.path) {
            loadedImage = preview
            if preview.size.height > 0 {
                aspectRatio = preview.size.width / preview.size.height
            }
        }
    }

    /// Second-stage load: build the `Spatial3DImage` and run `generate()`.
    /// Triggered by the side menu's "View in 3D" button.
    @MainActor
    private func loadSpatial() async {
        guard !spatialLoading, !spatialReady, let localURL else { return }
        spatialLoading = true
        spatialFailed = false

        let maxDim = appModel.spatial3DMaxResolution

        let spatial: ImagePresentationComponent.Spatial3DImage
        do {
            if maxDim > 0,
               let downsampled = PhotoWindowModel.createDownsampledImageData(from: localURL, maxDimension: CGFloat(maxDim)),
               let source = CGImageSourceCreateWithData(downsampled as CFData, nil) {
                spatial = try await ImagePresentationComponent.Spatial3DImage(imageSource: source)
            } else {
                spatial = try await ImagePresentationComponent.Spatial3DImage(contentsOf: localURL)
            }
        } catch {
            AppLogger.views.warning("QuickLook3DView: Spatial3DImage init failed: \(error.localizedDescription, privacy: .public)")
            spatialLoading = false
            spatialFailed = true
            return
        }

        if Task.isCancelled { spatialLoading = false; return }

        var ipc = ImagePresentationComponent(spatial3DImage: spatial)
        ipc.desiredViewingMode = .spatial3D
        entity.components.set(ipc)
        if let ar = ipc.aspectRatio(for: .spatial3D) {
            aspectRatio = CGFloat(ar)
        }

        // Strong-ref hold across generate(): RealityKit's progress
        // callbacks crash if the entity is freed mid-flight. Mirrors
        // SlideshowSpatial3DSlotView's pattern.
        let heldEntity = entity
        let heldSpatial = spatial
        Task { @MainActor in
            do {
                try await heldSpatial.generate()
                withAnimation(.easeInOut(duration: 0.25)) {
                    spatialReady = true
                }
            } catch {
                AppLogger.views.warning("QuickLook3DView: generate failed: \(error.localizedDescription, privacy: .public)")
                spatialFailed = true
            }
            spatialLoading = false
            _ = heldEntity
        }
    }
}

private extension View {
    @ViewBuilder
    func matchedGeometryEffectIfActive(id: some Hashable, namespace: Namespace.ID?, active: Bool) -> some View {
        if active, let namespace {
            self.matchedGeometryEffect(id: id, in: namespace, isSource: false)
        } else {
            self
        }
    }
}
