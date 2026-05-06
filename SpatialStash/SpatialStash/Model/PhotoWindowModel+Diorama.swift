/*
 Spatial Stash - Photo Window Model: Diorama

 Diorama mode renders the masked foreground (uncropped — full source frame
 with transparent background) floating in front of the unmodified backdrop
 via SwiftUI `.offset(z:)`. No RealityKit, no 3D engine — just visionOS
 spatial layering. Reuses the existing background-removal pipeline through
 a sibling cache namespace so a once-processed image stays cheap on reopen.

 Diorama is a sibling viewing mode to spatial 3D — engaged from the 3D
 menu, mutually exclusive with the RealityKit-based 3D modes.
 */

import Foundation
import os
import RealityKit
import SwiftUI

extension PhotoWindowModel {

    /// Toggle diorama mode for the current image. When turning on, ensures
    /// the uncropped foreground is loaded (from cache or freshly generated).
    func toggleDiorama() async {
        recordInteraction()
        await setDioramaMode(!isDioramaMode)
    }

    /// Set diorama mode explicitly. Engaging diorama exits any 3D mode.
    func setDioramaMode(_ on: Bool) async {
        if on {
            // Diorama is incompatible with RealityKit 3D — drop out of 3D first.
            if is3DMode || desiredViewingMode != .mono {
                await switchToViewingMode(.mono)
            }
            // Diorama is also mutually exclusive with background removal —
            // mixing the masked foreground with the bg-removed display texture
            // produces a broken composite (two foreground copies), so restore
            // the original display first, then drop cached bg-removal state.
            if backgroundRemovalState == .removed {
                restoreOriginalBackground()
            }
            if backgroundRemovalState != .original {
                clearBackgroundRemovalState()
            }
            // Load fg/bg first so the diorama layers don't pop in after the
            // mode flag flips. ensureDioramaForegroundLoaded uses imageURL as
            // its identity guard, so it's safe to call before isDioramaMode.
            await ensureDioramaForegroundLoaded()
            isDioramaMode = true
            await trackViewingMode(.diorama)
        } else {
            isDioramaMode = false
            await trackViewingMode(.mono)
        }
    }

    /// Load the diorama foreground + backdrop pair from cache, or generate and
    /// cache it. No-op if already loaded for the current image.
    func ensureDioramaForegroundLoaded() async {
        if dioramaForegroundImage != nil && dioramaBackdropImage != nil { return }
        if isProcessingDiorama { return }

        // Disk cache hit (need both variants — partial hit falls through to regen)
        if let fgData = await BackgroundRemovalCache.shared.loadDioramaForegroundData(for: imageURL),
           let bgData = await BackgroundRemovalCache.shared.loadDioramaBackdropData(for: imageURL),
           let fg = UIImage(data: fgData),
           let bg = UIImage(data: bgData) {
            dioramaForegroundImage = fg
            dioramaBackdropImage = bg
            return
        }

        // Need to generate. Use the original full-resolution image data when
        // available (matches the bg-removal path's preference for clean edges).
        guard let imageData = currentImageData, let fullResImage = UIImage(data: imageData) else {
            AppLogger.photoWindow.warning("No image data available for diorama foreground generation")
            return
        }

        isProcessingDiorama = true
        let url = imageURL
        let task = Task { @MainActor [weak self] in
            defer { Task { @MainActor [weak self] in self?.isProcessingDiorama = false } }
            do {
                let pair = try await BackgroundRemover.shared.generateDioramaPair(from: fullResImage)
                guard !Task.isCancelled, let self else { return }
                guard self.imageURL == url else { return }
                if let fg = pair.foreground {
                    self.dioramaForegroundImage = fg
                    await BackgroundRemovalCache.shared.saveDioramaForeground(fg, for: url)
                }
                if let bg = pair.backdrop {
                    self.dioramaBackdropImage = bg
                    await BackgroundRemovalCache.shared.saveDioramaBackdrop(bg, for: url)
                }
            } catch {
                AppLogger.photoWindow.error("Diorama generation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        dioramaTask = task
        await task.value
        dioramaTask = nil
    }

    /// Clear the in-memory diorama state. Called when switching to a different image.
    func clearDioramaState() {
        dioramaTask?.cancel()
        dioramaTask = nil
        dioramaForegroundImage = nil
        dioramaBackdropImage = nil
        isProcessingDiorama = false
        isDioramaMode = false
    }
}
