/*
 Spatial Stash - Shared Video Window View

 Pop-out player for videos received via the system share sheet.
 Uses AVPlayerViewController for native playback controls.
 Includes a Save button to persist the video to Documents/Videos/.
 */

import os
import SwiftUI

struct SharedVideoWindowView: View {
    let item: SharedMediaItem
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    @State private var isSaving = false
    @State private var isSaved = false
    @State private var saveError: String?

    var body: some View {
        Group {
            if FileManager.default.fileExists(atPath: item.cachedFileURL.path) {
                LocalVideoPlayerView(videoURL: item.cachedFileURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailableContent
            }
        }
        .ornament(
            attachmentAnchor: .scene(.bottomFront),
            ornament: {
                SharedVideoOrnament(
                    isSaving: isSaving,
                    isSaved: isSaved,
                    saveError: saveError,
                    onSave: saveVideo,
                    onOpenGallery: { openWindow(id: "main") }
                )
            }
        )
        .onDisappear {
            Task {
                await SharedMediaCache.shared.removeCachedFile(for: item.id)
            }
        }
    }

    private var unavailableContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "video.slash")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("Shared video is no longer available")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("The temporary cache was cleared.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func saveVideo() {
        guard !isSaving && !isSaved else { return }
        isSaving = true
        saveError = nil

        Task {
            do {
                _ = try SharedMediaSaver.saveVideo(
                    from: item.cachedFileURL,
                    originalFileName: item.originalFileName
                )
                isSaved = true
            } catch {
                saveError = error.localizedDescription
                AppLogger.sharedMedia.error("Failed to save shared video: \(error.localizedDescription, privacy: .public)")
            }
            isSaving = false
        }
    }
}

// MARK: - Ornament

struct SharedVideoOrnament: View {
    let isSaving: Bool
    let isSaved: Bool
    let saveError: String?
    let onSave: () -> Void
    let onOpenGallery: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Show main gallery window
            Button(action: onOpenGallery) {
                Image(systemName: "square.grid.2x2")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help("Show Gallery")

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
