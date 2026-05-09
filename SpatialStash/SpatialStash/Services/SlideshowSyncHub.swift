/*
 Spatial Stash - Slideshow Sync Hub

 Local Display Sync — when a model with Display Sync enabled transitions
 a post, the hub broadcasts the new state to other slideshow instances
 so they adopt the same current/next image, cached post queue, and
 delay. UIImage/Data are reference types so payloads are passed by
 reference, not copied.

 Used in gallery mode only. Remote (WS) mode lets the server's channel /
 displaySync merge keep windows in lockstep — running local sync there
 too would race the server's `playback` frames and pull peer windows
 out of sync with other connected clients (browser kiosks, node-display).
 */

import Foundation
import UIKit
import os

/// Snapshot of a slideshow's live state, broadcast to other local instances.
/// All image/data fields are reference-typed — no bitmap copies.
struct LocalDisplaySyncPayload {
    let currentPost: RemotePost?
    let currentImage: UIImage?
    let currentImageURL: URL?
    let currentMediaType: SlideshowEngine.SlideshowMediaType
    let isCurrentPostAnimatedGIF: Bool
    let prefetched: [(post: RemotePost, image: UIImage, url: URL)]
    let cachedPosts: [RemotePost]
    let delay: TimeInterval
}

@MainActor
final class SlideshowSyncHub {
    static let shared = SlideshowSyncHub()

    private init() {}

    // MARK: - Shared WebSocket connections

    /// One RemoteWebSocketClient per WS endpoint URL. Multiple viewer
    /// windows pointed at the same endpoint share one connection and
    /// multiplex under different sessionIds — see protocol.md.
    private var wsClientsByEndpoint: [String: RemoteWebSocketClient] = [:]

    /// Acquire a session on the shared client for `endpoint`. The client
    /// is created lazily on the first call and torn down by the matching
    /// `unsubscribeWS` once the last session leaves.
    func subscribeWS(endpoint: String, sessionId: String) -> RemoteWSSession {
        let client = wsClientsByEndpoint[endpoint] ?? {
            let c = RemoteWebSocketClient()
            wsClientsByEndpoint[endpoint] = c
            return c
        }()
        let handlers = client.attachSession(sessionId: sessionId, wsEndpoint: endpoint)
        return RemoteWSSession(client: client, sessionId: sessionId, endpoint: endpoint, handlers: handlers)
    }

    func unsubscribeWS(_ session: RemoteWSSession) {
        guard let client = wsClientsByEndpoint[session.endpoint] else { return }
        let remaining = client.detachSession(sessionId: session.sessionId)
        if remaining == 0 {
            client.disconnect()
            wsClientsByEndpoint.removeValue(forKey: session.endpoint)
        }
    }

    // MARK: - Local Display Sync Broadcast

    private final class WeakModelRef {
        weak var value: RemoteViewerModel?
        init(_ value: RemoteViewerModel) { self.value = value }
    }

    private var syncParticipants: [ObjectIdentifier: WeakModelRef] = [:]

    func registerForLocalSync(_ model: RemoteViewerModel) {
        syncParticipants[ObjectIdentifier(model)] = WeakModelRef(model)
    }

    func unregisterForLocalSync(_ model: RemoteViewerModel) {
        syncParticipants.removeValue(forKey: ObjectIdentifier(model))
    }

    /// Deliver a display-sync snapshot to every other registered model.
    /// The sender is skipped to avoid echo; stale weak refs are pruned.
    func broadcastLocalSync(from sender: RemoteViewerModel, payload: LocalDisplaySyncPayload) {
        let senderId = ObjectIdentifier(sender)
        var toPrune: [ObjectIdentifier] = []
        for (id, ref) in syncParticipants where id != senderId {
            if let model = ref.value {
                model.applyLocalDisplaySync(payload)
            } else {
                toPrune.append(id)
            }
        }
        for id in toPrune { syncParticipants.removeValue(forKey: id) }
    }
}
