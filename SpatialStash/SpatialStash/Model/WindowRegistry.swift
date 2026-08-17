/*
 Spatial Stash - Window Registry

 Tracks every open secondary window scene (kind, opening payload, and whether
 it is in the user's current room) so the Settings "Windows" manager can list,
 close, and summon them — Longwave's Sessions-tab pattern, extended to
 per-instance identity because this app opens many windows of the same kind.

 Summon is deliberately a recycle (dismiss the old scene, open a fresh one with
 the same content) rather than an `openWindow` recall of the existing value:
 on visionOS 27 the room-persistence service can re-activate a parked scene
 without ever re-attaching it to a compositor placement, leaving the window
 permanently invisible and non-interactable (see
 internal_docs/visionos27-invisible-window-feedback.md). Nothing app-side can
 force such a scene to draw again — geometry round-trips don't recover it and
 even a plain SwiftUI Text never lays out — so destroying the scene session and
 opening a fresh scene is the only recovery, and it doubles as "bring this
 window to me".
 */

import Foundation
import SwiftUI

/// The payload a managed window scene was opened with — enough to dismiss the
/// scene (value-matched) and to open an equivalent fresh scene.
enum ManagedWindowContent: Equatable {
    case photo(PhotoWindowValue)
    case video(VideoWindowValue)
    case sharedMedia(SharedMediaItem)
    case remoteViewer(RemoteViewerWindowValue)
    case remoteAlert(RemoteAlertWindowValue)
    /// Plain `Window` scenes (console, GPU monitor, video adjustments): no
    /// value — the scene id alone identifies the one instance.
    case singleton
}

@MainActor
@Observable
final class WindowRegistry {
    static let shared = WindowRegistry()

    struct Entry: Identifiable {
        /// Registration token, stable for the scene's lifetime (NOT the window
        /// value's id — the value is replaced when the window is recycled).
        let id: UUID
        let sceneID: String
        var content: ManagedWindowContent
        /// `true` while the scene phase is `.active` (in the user's current
        /// room), `false` when parked in another room or otherwise backgrounded.
        var isInActiveRoom: Bool = true
        let openedAt = Date()
    }

    private(set) var windows: [Entry] = []

    private init() {}

    // MARK: - Lifecycle bookkeeping (driven by the `managedWindow` modifier)

    func register(token: UUID, sceneID: String, content: ManagedWindowContent) {
        guard !windows.contains(where: { $0.id == token }) else { return }
        windows.append(Entry(id: token, sceneID: sceneID, content: content))
    }

    func unregister(token: UUID) {
        windows.removeAll { $0.id == token }
    }

    func setActiveRoom(token: UUID, _ active: Bool) {
        guard let index = windows.firstIndex(where: { $0.id == token }) else { return }
        windows[index].isInActiveRoom = active
    }

    // MARK: - Actions

    /// Close the window's scene.
    func close(_ entry: Entry, dismiss: DismissWindowAction) {
        switch entry.content {
        case .photo(let value): dismiss(id: entry.sceneID, value: value)
        case .video(let value): dismiss(id: entry.sceneID, value: value)
        case .sharedMedia(let value): dismiss(id: entry.sceneID, value: value)
        case .remoteViewer(let value): dismiss(id: entry.sceneID, value: value)
        case .remoteAlert(let value): dismiss(id: entry.sceneID, value: value)
        case .singleton: dismiss(id: entry.sceneID)
        }
    }

    /// Bring the window to the user by recycling its scene: dismiss the old
    /// scene and open a fresh one carrying the same content. Value-typed
    /// windows open under a NEW instance id in the same turn — the fresh value
    /// can never match the dying scene, so there is no teardown race. Windows
    /// whose value can't change identity (shared media) and the singleton
    /// `Window` scenes wait for the old scene to actually disconnect first,
    /// else the reopen would just recall the scene being torn down.
    func summon(_ entry: Entry, open: OpenWindowAction, dismiss: DismissWindowAction) {
        switch entry.content {
        case .photo(let value):
            dismiss(id: entry.sceneID, value: value)
            open(id: entry.sceneID, value: value.recreated())
        case .video(let value):
            dismiss(id: entry.sceneID, value: value)
            open(id: entry.sceneID, value: value.recreated())
        case .remoteViewer(let value):
            dismiss(id: entry.sceneID, value: value)
            open(id: entry.sceneID, value: value.recreated())
        case .remoteAlert(let value):
            dismiss(id: entry.sceneID, value: value)
            open(id: entry.sceneID, value: RemoteAlertWindowValue(
                text: value.text, bgColorHex: value.bgColorHex, imageUrl: value.imageUrl
            ))
        case .sharedMedia(let value):
            dismiss(id: entry.sceneID, value: value)
            reopenAfterTeardown(token: entry.id) { open(id: entry.sceneID, value: value) }
        case .singleton:
            dismiss(id: entry.sceneID)
            reopenAfterTeardown(token: entry.id) { open(id: entry.sceneID) }
        }
    }

    /// Wait (bounded) for the entry's scene to unregister, then reopen. If the
    /// scene refuses to die within the timeout, reopen anyway — recalling a
    /// live scene beats leaving the user with nothing.
    private func reopenAfterTeardown(token: UUID, _ reopen: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            for _ in 0..<60 {
                if !windows.contains(where: { $0.id == token }) { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            reopen()
        }
    }
}

// MARK: - Fresh-identity clones

extension PhotoWindowValue {
    /// Same content under a fresh window identity. `wasPushed` is dropped —
    /// the recreated window has no originating gallery window to pop back to,
    /// so it gets the standalone chrome (gallery button) instead.
    func recreated() -> PhotoWindowValue {
        var value = PhotoWindowValue(image: image, wasPushed: false)
        value.restoredSize = restoredSize
        return value
    }
}

extension VideoWindowValue {
    /// Same content under a fresh window identity (see `PhotoWindowValue`).
    func recreated() -> VideoWindowValue {
        var value = VideoWindowValue(
            video: video,
            galleryVideos: galleryVideos,
            stereoscopicOverride: stereoscopicOverride,
            video3DSettings: video3DSettings,
            pseudo3DEnabled: pseudo3DEnabled,
            pseudo3DSettings: pseudo3DSettings,
            wasPushed: false
        )
        value.restoredSize = restoredSize
        return value
    }
}

extension RemoteViewerWindowValue {
    /// Same profile under a fresh window identity.
    func recreated() -> RemoteViewerWindowValue {
        var value = RemoteViewerWindowValue(configId: configId)
        value.restoredSize = restoredSize
        return value
    }
}

// MARK: - Registration modifier

/// Registers a window scene with `WindowRegistry` for its lifetime and keeps
/// its room status (scene phase) up to date. Apply to each secondary scene's
/// root content in `SpatialStashApp`.
private struct ManagedWindowModifier: ViewModifier {
    let sceneID: String
    let windowContent: ManagedWindowContent
    @State private var token = UUID()
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                WindowRegistry.shared.register(token: token, sceneID: sceneID, content: windowContent)
                WindowRegistry.shared.setActiveRoom(token: token, scenePhase == .active)
            }
            .onDisappear {
                WindowRegistry.shared.unregister(token: token)
            }
            .onChange(of: scenePhase) { _, phase in
                WindowRegistry.shared.setActiveRoom(token: token, phase == .active)
            }
    }
}

extension View {
    /// Track this scene in the window manager. The content snapshot is what a
    /// summon reopens with; identity-relevant fields never change after open
    /// (value equality is id-only), so registering once on appear is enough.
    func managedWindow(_ sceneID: String, content: ManagedWindowContent = .singleton) -> some View {
        modifier(ManagedWindowModifier(sceneID: sceneID, windowContent: content))
    }
}
