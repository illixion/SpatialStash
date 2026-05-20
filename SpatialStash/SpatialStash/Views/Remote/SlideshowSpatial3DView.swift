/*
 Spatial Stash - Slideshow Spatial 3D View

 RealityKit-backed image layer used by the slideshow viewer when
 `Slideshow3DMode` is `.spatial3D` or `.immersive3D`.

 `SlideshowSpatial3DSlotView` is a single slot: it owns one entity with an
 `ImagePresentationComponent`, rebuilds the component when the bound
 `UIImage` changes, and drives `Spatial3DImage.generate()` so the depth
 map is finished before the slot is asked to fade in.

 `SlideshowSpatial3DLayer` is the host the window view embeds — it owns
 two slots and swaps their roles each crossfade so the previously-hidden
 slot (which already finished generating against the prefetched next
 image) just becomes visible instead of regenerating from scratch.
 */

import ImageIO
import os
import RealityKit
import SwiftUI

/// Two-slot host that orchestrates pre-generation + crossfade. Slot A and
/// Slot B alternate which one is "currently visible" — whichever slot is
/// in the "hidden / next" role takes the engine's prefetched next image
/// and runs `Spatial3DImage.generate()` while the other is on screen, so
/// the eventual fade-in shows a finished depth map instead of restarting
/// the conversion animation.
struct SlideshowSpatial3DLayer: View {
    @Bindable var model: RemoteViewerModel

    /// Which slot currently holds the visible image (0 = A, 1 = B). Flipped
    /// after each crossfade so the hidden slot — which has been generating
    /// the prefetched image — promotes into the visible role without ever
    /// recreating its entity.
    @State private var visibleSlot: Int = 0
    @State private var slotA: UIImage?
    @State private var slotB: UIImage?
    /// Identity of the image currently displayed in the visible slot. Used
    /// to detect when `currentImage` has actually changed (i.e. crossfade
    /// committed) so role-swapping fires exactly once per transition.
    @State private var lastCommittedImage: ObjectIdentifier?

    var body: some View {
        let immersive = model.slideshow3DMode == .immersive3D
        let res = model.maxImageResolution3D
        let transitioning = model.isTransitioning

        ZStack {
            SlideshowSpatial3DSlotView(image: slotA, immersive: immersive, maxResolution: res)
                .opacity(opacity(forSlot: 0, transitioning: transitioning))
                .animation(.easeInOut(duration: model.reduceMotion ? 0 : 1.0), value: transitioning)

            SlideshowSpatial3DSlotView(image: slotB, immersive: immersive, maxResolution: res)
                .opacity(opacity(forSlot: 1, transitioning: transitioning))
                .animation(.easeInOut(duration: model.reduceMotion ? 0 : 1.0), value: transitioning)
        }
        .onAppear { syncSlots(force: true) }
        .onChange(of: identity(model.currentImage)) { _, _ in
            // Crossfade just committed — the previously hidden slot now
            // holds the visible image. Flip roles, then refill the freshly
            // hidden slot with the engine's next peek.
            handleCommit()
        }
        .onChange(of: identity(model.peekedNextImage)) { oldId, _ in
            // The engine pops `prefetchedImages.first` *before* it sets
            // `isTransitioning`, so an advance flips peek from the image
            // about to display (already loaded in our hidden slot) to
            // the one after it. Reacting to that shift would overwrite
            // the fully-generated incoming image and force a regen
            // mid-crossfade. Detect that case via "hidden currently
            // holds the old peek" and skip — `handleCommit` will refresh
            // hidden once the new current is known. All other peek
            // changes (cold-start fill, prefetch refill after a stall)
            // fall through and load normally.
            let hiddenSlot = 1 - visibleSlot
            let hiddenImage = hiddenSlot == 0 ? slotA : slotB
            let hiddenId = identity(hiddenImage)
            if hiddenId != nil, hiddenId == oldId { return }
            loadPeekIntoHiddenSlot()
        }
    }

    private func opacity(forSlot slot: Int, transitioning: Bool) -> Double {
        // The "visible" slot is fully opaque except during a crossfade,
        // when it fades out as the hidden slot fades in. Once the
        // crossfade commits we flip `visibleSlot`, which keeps the
        // newly-visible slot at opacity 1 without animation.
        let isVisible = slot == visibleSlot
        if transitioning {
            return isVisible ? 0 : 1
        } else {
            return isVisible ? 1 : 0
        }
    }

    private func identity(_ image: UIImage?) -> ObjectIdentifier? {
        guard let image else { return nil }
        return ObjectIdentifier(image)
    }

    private func syncSlots(force: Bool) {
        // Initial population: visible slot gets current image, hidden slot
        // takes the peeked next so it starts generating immediately.
        if visibleSlot == 0 {
            slotA = model.currentImage
            slotB = model.peekedNextImage
        } else {
            slotB = model.currentImage
            slotA = model.peekedNextImage
        }
        if force, let img = model.currentImage {
            lastCommittedImage = ObjectIdentifier(img)
        }
    }

    private func handleCommit() {
        guard let current = model.currentImage else {
            lastCommittedImage = nil
            return
        }
        let newId = ObjectIdentifier(current)
        guard newId != lastCommittedImage else { return }
        lastCommittedImage = newId

        // If the hidden slot already holds this image (the normal pre-gen
        // path), just flip roles — no regeneration. Otherwise the new
        // image bypassed the peek (manual navigation, tag-list change),
        // so install it into the now-hidden slot and flip; that slot will
        // generate on first display.
        let hiddenSlot = 1 - visibleSlot
        let hiddenImage = hiddenSlot == 0 ? slotA : slotB
        if identity(hiddenImage) != newId {
            assignSlot(hiddenSlot, image: current)
        }
        visibleSlot = hiddenSlot
        // The now-hidden slot will pick up the next peek via its own
        // onChange, but if a peek is already waiting we kick it now so
        // generation can start during the new displaying interval.
        loadPeekIntoHiddenSlot()
    }

    private func loadPeekIntoHiddenSlot() {
        let hiddenSlot = 1 - visibleSlot
        let hiddenImage = hiddenSlot == 0 ? slotA : slotB
        guard let peek = model.peekedNextImage else { return }
        // Don't reload if the hidden slot already shows this image —
        // would cause exactly the double-generation the slot view was
        // designed to avoid.
        if identity(hiddenImage) == ObjectIdentifier(peek) { return }
        // Skip if the current image is the peek (cold start: prefetch
        // hasn't refilled past the now-displayed item yet).
        if identity(model.currentImage) == ObjectIdentifier(peek) { return }
        assignSlot(hiddenSlot, image: peek)
    }

    private func assignSlot(_ slot: Int, image: UIImage?) {
        if slot == 0 { slotA = image } else { slotB = image }
    }
}

struct SlideshowSpatial3DSlotView: View {
    let image: UIImage?
    let immersive: Bool
    let maxResolution: Int

    @State private var entity = Entity()
    @State private var loadedKey: String?

    var body: some View {
        // GeometryReader3D + scale-to-fit mirrors PhotoDisplayView's
        // windowed 3D path: IPC's `presentationScreenSize` is in meters,
        // and the entity needs an explicit scale to match the SwiftUI
        // bounds — otherwise the spatial 3D scene renders at its native
        // size and crops in. Immersive mode is left at scale 1 since the
        // RealityView's bounds are the immersive space itself.
        GeometryReader3D { geometry in
            RealityView { content in
                content.add(entity)
                scaleEntityToFit(content: content, geometry: geometry)
            } update: { content in
                scaleEntityToFit(content: content, geometry: geometry)
            }
        }
        .task(id: cacheKey) {
            await reload()
        }
    }

    private func scaleEntityToFit(content: RealityViewContent, geometry: GeometryProxy3D) {
        guard !immersive else {
            entity.scale = SIMD3<Float>(1, 1, 1)
            return
        }
        guard let ipc = entity.components[ImagePresentationComponent.self] else { return }
        let presentationScreenSize = ipc.presentationScreenSize
        guard presentationScreenSize.x > 0, presentationScreenSize.y > 0 else { return }
        let bounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
        let scale = min(
            bounds.extents.x / presentationScreenSize.x,
            bounds.extents.y / presentationScreenSize.y
        )
        entity.scale = SIMD3<Float>(scale, scale, 1.0)
    }

    /// Cache key combines the image identity and the immersive flag so a
    /// mode flip re-derives the component (the viewing-mode toggle is set
    /// on the component itself).
    private var cacheKey: String {
        guard let image else { return "nil" }
        return "\(ObjectIdentifier(image).hashValue):\(immersive ? "imm" : "win"):\(maxResolution)"
    }

    @MainActor
    private func reload() async {
        guard let image else {
            entity.components.remove(ImagePresentationComponent.self)
            loadedKey = nil
            return
        }
        let key = cacheKey
        if loadedKey == key { return }

        guard let data = image.jpegData(compressionQuality: 0.95) else {
            AppLogger.remoteViewer.warning("SlideshowSpatial3DView: could not encode image data")
            return
        }

        do {
            let spatial = try await Self.makeSpatial3DImage(from: data)
            var ipc = ImagePresentationComponent(spatial3DImage: spatial)
            ipc.desiredViewingMode = immersive ? .spatial3DImmersive : .spatial3D
            entity.components.set(ipc)
            loadedKey = key
            // Kick off the depth-map generation in the background so the
            // next image's 3D conversion is ready in the hidden instance
            // by the time it gets promoted to current.
            try await spatial.generate()
        } catch {
            AppLogger.remoteViewer.warning("SlideshowSpatial3DView: Spatial3DImage init failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Build the `Spatial3DImage` off the main actor. The CGImageSource is
    /// created locally so it never crosses an actor boundary — the
    /// `Spatial3DImage` initializer is nonisolated and bridging the source
    /// from the main actor trips Swift 6's data-race check.
    private nonisolated static func makeSpatial3DImage(from data: Data) async throws -> ImagePresentationComponent.Spatial3DImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try await ImagePresentationComponent.Spatial3DImage(imageSource: source)
    }
}
