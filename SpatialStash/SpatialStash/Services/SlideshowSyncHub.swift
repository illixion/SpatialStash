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
    let prefetched: [(post: RemotePost, image: UIImage, url: URL, data: Data)]
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

    /// First connected pooled client — telemetry is process-wide, so any live
    /// connection will do as the transport.
    private func anyConnectedClient() -> RemoteWebSocketClient? {
        wsClientsByEndpoint.values.first(where: { $0.isConnected })
    }

    // MARK: - Device Telemetry (Console dev toggle)

    /// Provider injected by AppModel: builds a process-wide sample on demand
    /// (window counts + deviceId live there). nil ⇒ telemetry disabled.
    private var metricsProvider: (() -> DeviceMetrics)?
    private var telemetryTask: Task<Void, Never>?
    /// Sampling cadence. Frequent enough to capture the ramp that precedes an
    /// OOM, sparse enough to be negligible while idle.
    private static let telemetryInterval: Duration = .seconds(7)

    /// Enable/disable the process-wide telemetry ticker. Driven by the Console
    /// developer toggle. Idempotent. When enabled, periodically emits
    /// `reportMetrics` over any live pooled connection; when disabled, stops.
    func setTelemetryEnabled(_ enabled: Bool, provider: (() -> DeviceMetrics)?) {
        metricsProvider = enabled ? provider : nil
        telemetryTask?.cancel()
        telemetryTask = nil
        guard enabled, provider != nil else { return }
        telemetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.telemetryInterval)
                guard !Task.isCancelled, let self, let provider = self.metricsProvider else { break }
                if let client = self.anyConnectedClient() {
                    client.sendReportMetrics(provider())
                }
            }
        }
    }

    /// Emit an event-driven log line over telemetry. No-op unless telemetry is
    /// enabled and a connection is live. deviceId/app are taken from the current
    /// metrics provider so callers don't need to know them.
    func emitTelemetryLog(level: String, domain: String, message: String) {
        guard let provider = metricsProvider, let client = anyConnectedClient() else { return }
        let m = provider()
        client.sendReportLog(deviceId: m.deviceId, app: m.app, level: level, domain: domain, message: message)
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
