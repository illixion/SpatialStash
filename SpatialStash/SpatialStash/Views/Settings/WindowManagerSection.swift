/*
 Spatial Stash - Window Manager Section

 Settings section listing every open secondary window (via WindowRegistry)
 with per-window Summon and Close, plus the bulk hide/close controls that used
 to live in the Developer section. Summon recycles the scene — dismiss + fresh
 open — which both brings a window parked in another room to the user and
 recovers a window the visionOS 27 invisible-window bug has orphaned (see
 internal_docs/visionos27-invisible-window-feedback.md); a plain openWindow
 recall of the existing scene is exactly what triggers that bug.
 */

import os
import SwiftUI

struct WindowManagerSection: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var registry: WindowRegistry { .shared }

    var body: some View {
        Section {
            if registry.windows.isEmpty {
                Text("No other windows are open.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(registry.windows) { entry in
                    windowRow(entry)
                }
            }

            Button(appModel.allWindowsHidden ? "Unhide All Windows" : "Hide All Windows") {
                appModel.allWindowsHidden.toggle()
            }
            .disabled(!hasSecondaryWindows && !appModel.allWindowsHidden)

            Button("Close All Windows", role: .destructive) {
                closeAllSecondaryWindows()
                appModel.allWindowsHidden = false
            }
            .disabled(!hasSecondaryWindows)
        } header: {
            Text("Windows")
        } footer: {
            Text("Summon closes a window and reopens it in front of you. Use it to retrieve a window left in another room — or to recover one that has gone invisible (a visionOS 27 bug).")
        }
    }

    private func windowRow(_ entry: WindowRegistry.Entry) -> some View {
        let kind = kindInfo(entry)
        return HStack(spacing: 12) {
            Image(systemName: kind.icon)
                .font(.title3)
                .frame(width: 32)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.headline)
                if let subtitle = subtitle(entry), !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Label(
                    entry.isInActiveRoom ? "In this room" : "In another room",
                    systemImage: entry.isInActiveRoom ? "location.fill" : "location.slash"
                )
                .font(.caption)
                .foregroundStyle(entry.isInActiveRoom ? Color.secondary : Color.orange)
            }

            Spacer()

            Button {
                registry.summon(entry, open: openWindow, dismiss: dismissWindow)
            } label: {
                Label("Summon", systemImage: "arrow.down.right.and.arrow.up.left.rectangle")
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                registry.close(entry, dismiss: dismissWindow)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close this window")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Row labels

    private func kindInfo(_ entry: WindowRegistry.Entry) -> (title: String, icon: String) {
        switch entry.content {
        case .photo:
            return ("Photo", "photo")
        case .video:
            return ("Video", "play.rectangle")
        case .sharedMedia(let item):
            return item.mediaType == .video
                ? ("Shared Video", "square.and.arrow.down")
                : ("Shared Photo", "square.and.arrow.down")
        case .remoteViewer(let value):
            if appModel.remoteViewerConfig(id: value.configId)?.mode == .webPage {
                return ("Web Page", "globe")
            }
            return ("Slideshow", "play.square.stack")
        case .remoteAlert:
            return ("Alert", "exclamationmark.bubble")
        case .singleton:
            switch entry.sceneID {
            case "console": return ("Console", "terminal")
            case "gpu-memory": return ("GPU Memory", "memorychip")
            case "video-adjustments": return ("Adjustments", "slider.horizontal.3")
            default: return (entry.sceneID, "macwindow")
            }
        }
    }

    private func subtitle(_ entry: WindowRegistry.Entry) -> String? {
        switch entry.content {
        case .photo(let value):
            return value.image.title ?? value.image.fileName
                ?? value.image.fullSizeURL.lastPathComponent
        case .video(let value):
            return value.video.title
        case .sharedMedia(let item):
            return item.originalFileName
        case .remoteViewer(let value):
            return appModel.remoteViewerConfig(id: value.configId)?.name
        case .remoteAlert(let value):
            return value.text
        case .singleton:
            return nil
        }
    }

    // MARK: - Bulk controls

    /// Whether any secondary (non-main) window scenes are currently connected.
    /// UIKit-scene based rather than registry based, so it also catches scenes
    /// that failed to register (e.g. mid-restoration).
    private var hasSecondaryWindows: Bool {
        let mainSession = sceneDelegate?.windowScene?.session
        return UIApplication.shared.connectedScenes.contains { scene in
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.session.role == .windowApplication else {
                return false
            }
            return windowScene.session !== mainSession
        }
    }

    /// Close all secondary windows by requesting scene destruction.
    private func closeAllSecondaryWindows() {
        let mainSession = sceneDelegate?.windowScene?.session
        let secondaryScenes = UIApplication.shared.connectedScenes.compactMap { scene -> UISceneSession? in
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.session.role == .windowApplication,
                  windowScene.session !== mainSession else {
                return nil
            }
            return windowScene.session
        }

        for session in secondaryScenes {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }

        AppLogger.settings.info("Closed \(secondaryScenes.count, privacy: .public) secondary windows")
    }
}
