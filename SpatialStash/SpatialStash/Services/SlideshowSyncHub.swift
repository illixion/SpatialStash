/*
 Spatial Stash - Slideshow Sync Hub

 Shared services for multiple RemoteViewerModel instances:

 1. WebSocket connection pooling — when multiple slideshows target the same
    WS URL, they share a single RemoteWebSocketClient. RoboFrame server
    messages are broadcast to every subscriber. Per-subscriber outgoing
    messages (visibility, etc.) pass their own device ID.

 2. Local Display Sync — when a model with Display Sync enabled transitions
    a post, the hub broadcasts the new state to other slideshow instances
    so they adopt the same current/next image, cached post queue, cursor,
    and delay. UIImage/Data are reference types so payloads are passed by
    reference, not copied.
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

    // MARK: - WS Connection Pool

    struct WSSubscriptionToken {
        let endpoint: String
        let id: UUID
        let deviceId: String
    }

    private struct WSSubscriber {
        let id: UUID
        let deviceId: String
        let onMessage: (RemoteWSMessage) -> Void
    }

    private final class SharedConnection {
        let endpoint: String
        let client: RemoteWebSocketClient
        var subscribers: [UUID: WSSubscriber] = [:]
        init(endpoint: String, client: RemoteWebSocketClient) {
            self.endpoint = endpoint
            self.client = client
        }
    }

    private var connections: [String: SharedConnection] = [:]

    /// Subscribe to a WS endpoint. If a connection for this URL already
    /// exists, the new subscriber piggybacks on it and receives every
    /// incoming message. The first subscriber's device ID is used for
    /// the initial getDisplayState request on connect.
    func subscribeWS(
        endpoint: String,
        deviceId: String,
        onMessage: @escaping (RemoteWSMessage) -> Void
    ) -> (token: WSSubscriptionToken, client: RemoteWebSocketClient)? {
        guard !endpoint.isEmpty else { return nil }

        let subId = UUID()
        let subscriber = WSSubscriber(id: subId, deviceId: deviceId, onMessage: onMessage)

        if let existing = connections[endpoint] {
            existing.subscribers[subId] = subscriber
            AppLogger.remoteViewer.info("WS subscriber joined existing connection (\(existing.subscribers.count, privacy: .public) total)")
            // Request display state for this specific device
            if !deviceId.isEmpty {
                existing.client.sendVisibilityChange(deviceId: deviceId, visible: true)
            }
            return (WSSubscriptionToken(endpoint: endpoint, id: subId, deviceId: deviceId), existing.client)
        }

        let client = RemoteWebSocketClient()
        let shared = SharedConnection(endpoint: endpoint, client: client)
        shared.subscribers[subId] = subscriber

        client.onMessage = { [weak shared] message in
            guard let shared else { return }
            for sub in shared.subscribers.values {
                if Self.shouldDeliver(message, to: sub) {
                    sub.onMessage(message)
                }
            }
        }

        connections[endpoint] = shared
        client.connect(wsEndpoint: endpoint, deviceId: deviceId)
        AppLogger.remoteViewer.info("WS opened new shared connection")

        return (WSSubscriptionToken(endpoint: endpoint, id: subId, deviceId: deviceId), client)
    }

    /// Per-channel routing for messages whose payload is scoped to a
    /// specific deviceId. Without this filter, two windows on the same
    /// shared WS but different deviceIds would each apply the other's
    /// `playback` frames — they'd lockstep on the union of both channels'
    /// queues and visibly skip every other image. While `mergeDriver` is
    /// set, the merge is active server-side and every subscriber is
    /// expected to mirror the driver's channel, so we deliver to all.
    private static func shouldDeliver(_ message: RemoteWSMessage, to sub: WSSubscriber) -> Bool {
        switch message {
        case .playback(let payload):
            if payload["mergeDriver"] is String { return true }
            guard let frameDeviceId = payload["deviceId"] as? String else { return true }
            // Empty subscriber deviceId = legacy / unconfigured — receive everything
            // rather than going silent.
            if sub.deviceId.isEmpty { return true }
            return frameDeviceId == sub.deviceId
        default:
            return true
        }
    }

    func unsubscribeWS(_ token: WSSubscriptionToken?) {
        guard let token, let shared = connections[token.endpoint] else { return }
        shared.subscribers.removeValue(forKey: token.id)
        if shared.subscribers.isEmpty {
            shared.client.disconnect()
            connections.removeValue(forKey: token.endpoint)
            AppLogger.remoteViewer.info("WS last subscriber left — closed shared connection")
        } else {
            AppLogger.remoteViewer.info("WS subscriber left (\(shared.subscribers.count, privacy: .public) remaining)")
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
