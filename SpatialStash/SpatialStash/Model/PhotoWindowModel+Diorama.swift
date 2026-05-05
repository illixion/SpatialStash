/*
 Spatial Stash - Photo Window Model: Diorama

 Diorama mode renders the masked foreground (uncropped — full source frame
 with transparent background) floating in front of the unmodified backdrop
 via SwiftUI `.offset(z:)`. No RealityKit, no 3D engine — just visionOS
 spatial layering. Reuses the existing background-removal pipeline through
 a sibling cache namespace so a once-processed image stays cheap on reopen.
 */

import Foundation
import os
import SwiftUI

extension PhotoWindowModel {

    /// Toggle diorama mode for the current image. When turning on, ensures
    /// the uncropped foreground is loaded (from cache or freshly generated).
    func toggleDiorama() async {
        recordInteraction()
        currentAdjustments.isDiorama.toggle()
        await persistAdjustments()
        if currentAdjustments.isDiorama {
            await ensureDioramaForegroundLoaded()
        }
    }

    /// Load the uncropped foreground from cache, or generate and cache it.
    /// No-op if already loaded for the current image.
    func ensureDioramaForegroundLoaded() async {
        if dioramaForegroundImage != nil { return }
        if isProcessingDiorama { return }

        // Disk cache hit
        if let data = await BackgroundRemovalCache.shared.loadDioramaForegroundData(for: imageURL),
           let image = UIImage(data: data) {
            dioramaForegroundImage = image
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
                guard let foreground = try await BackgroundRemover.shared.removeBackgroundUncropped(from: fullResImage) else {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                // Bail out if the user navigated to a different image while we worked.
                guard self.imageURL == url else { return }
                self.dioramaForegroundImage = foreground
                await BackgroundRemovalCache.shared.saveDioramaForeground(foreground, for: url)
            } catch {
                AppLogger.photoWindow.error("Diorama foreground generation failed: \(error.localizedDescription, privacy: .public)")
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
        isProcessingDiorama = false
    }

    private func persistAdjustments() async {
        guard appModel.rememberImageEnhancements else { return }
        await ImageEnhancementTracker.shared.setAdjustments(url: imageURL, adjustments: currentAdjustments)
    }
}
