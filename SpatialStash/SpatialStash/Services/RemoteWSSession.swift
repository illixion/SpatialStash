/*
 Spatial Stash - Remote WebSocket Session

 A thin facade over a shared RemoteWebSocketClient connection that
 stamps the right sessionId on every outbound frame. Acquired from
 SlideshowSyncHub.subscribeWS — that's where connection pooling and
 refcount-driven teardown live. Multiple viewer windows pointed at the
 same WS endpoint share one TCP/TLS path and one server-side ws, each
 multiplexed under its own sessionId.
 */

import Foundation

@MainActor
final class RemoteWSSession {
    let sessionId: String
    let endpoint: String
    private(set) weak var client: RemoteWebSocketClient?
    private let handlers: RemoteWSSessionHandlers

    init(client: RemoteWebSocketClient, sessionId: String, endpoint: String, handlers: RemoteWSSessionHandlers) {
        self.client = client
        self.sessionId = sessionId
        self.endpoint = endpoint
        self.handlers = handlers
    }

    var onMessage: ((RemoteWSMessage) -> Void)? {
        get { handlers.onMessage }
        set { handlers.onMessage = newValue }
    }

    var onConnected: (() -> Void)? {
        get { handlers.onConnected }
        set { handlers.onConnected = newValue }
    }

    var sensorData: [String: HASensorReading] { client?.sensorData ?? [:] }
    var isConnected: Bool { client?.isConnected ?? false }

    func sendSlideshowConfig(deviceId: String, interval: Int, width: Int, height: Int, bright: Bool, convert: Bool, ratio: String? = nil, modTags: [String] = []) {
        client?.sendSlideshowConfig(sessionId: sessionId, deviceId: deviceId, interval: interval, width: width, height: height, bright: bright, convert: convert, ratio: ratio, modTags: modTags)
    }

    func sendVisibilityChange(deviceId: String, visible: Bool) {
        // visibility is keyed on deviceId at the server, no sessionId.
        client?.sendVisibilityChange(deviceId: deviceId, visible: visible)
    }

    func sendBlock(postId: Int) {
        client?.sendBlock(postId: postId)
    }

    func sendDisplaySync(enabled: Bool) {
        client?.sendDisplaySync(sessionId: sessionId, enabled: enabled)
    }

    func sendSetModTags(tags: [String]) {
        client?.sendSetModTags(sessionId: sessionId, tags: tags)
    }

    func sendSetTagList(listNumber: Int) {
        // setTagList is per-channel — the server uses the sessionId to
        // resolve the deviceId and scopes the change to that channel.
        client?.sendSetTagList(sessionId: sessionId, listNumber: listNumber)
    }

    func sendRequestNext() {
        client?.sendRequestNext(sessionId: sessionId)
    }

    func sendImageReady(postId: Int) {
        client?.sendImageReady(sessionId: sessionId, postId: postId)
    }

    func forceReconnectNow() {
        client?.forceReconnectNow()
    }

    func probeOrReconnect() {
        client?.probeOrReconnect()
    }

    /// Drop just this session. The shared connection stays up if any
    /// other sessions are still attached; the hub closes it when the
    /// last subscriber leaves.
    func close() {
        SlideshowSyncHub.shared.unsubscribeWS(self)
    }
}
