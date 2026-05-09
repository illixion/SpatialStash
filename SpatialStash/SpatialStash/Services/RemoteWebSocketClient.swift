/*
 Spatial Stash - Remote WebSocket Client

 Manages WebSocket connection for real-time control, sensor data,
 and cross-device synchronization with the RoboFrame server.
 */

import Foundation
import Network
import os

struct HASensorReading: Identifiable {
    let entityId: String
    var state: String
    var friendlyName: String
    var unitOfMeasurement: String
    var isUnavailable: Bool = false
    var lastKnownState: String?

    var id: String { entityId }

    var displayEmoji: String {
        let name = friendlyName.lowercased()
        if name.contains("temperature") { return "\u{1F321}\u{FE0F}" }
        if name.contains("humidity") { return "\u{1F4A7}" }
        if name.contains("pressure") { return "\u{1F32C}\u{FE0F}" }
        if name.contains("co2") || name.contains("carbon") { return "\u{2601}\u{FE0F}" }
        return ""
    }
}

enum RemoteWSMessage {
    case tagLists(lists: [[String]])
    case currentTagList(index: Int)
    case showText(text: String, bgColorHex: String, imageUrl: String?)
    case dismissText
    case playAudio(url: URL)
    case stopAudio
    case sensorUpdate(entityId: String, state: String, friendlyName: String, unit: String)
    case refresh
    /// Server → client playback channel state. The orchestrator pushes this
    /// on every channel change (advance, displaySync claim, tag list change,
    /// mod-tag change). Payload shape:
    ///   { deviceId: String, mergeDriver: String?, interval: Int (ms),
    ///     currentList: Int, modTags: [String],
    ///     current: { id: Int, ext: String }?, next: { id: Int, ext: String }?,
    ///     upcoming: [{ id: Int, ext: String }] }
    case playback(payload: [String: Any])
    /// Server rejected the upgrade with close code 1008 (policy violation).
    /// Emitted once; reconnects are halted until the next explicit connect.
    case fatalAuthError(reason: String)
}

@MainActor
@Observable
class RemoteWebSocketClient {
    var sensorData: [String: HASensorReading] = [:]
    var isConnected: Bool = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var wsURL: URL?
    /// Device ID used for the initial visibility ping on (re)connect.
    /// Additional subscribers send their own device IDs via `sendVisibilityChange(deviceId:)`.
    private var initialDeviceId: String = ""
    private var reconnectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var retryCount: Int = 0
    private static let maxRetryDelay: TimeInterval = 30
    /// Interval between application-level `ping` frames. The server
    /// expects JSON `{action: "ping"}` and replies with `{action: "pong"}`.
    private static let pingInterval: TimeInterval = 25
    /// How long to wait for any inbound traffic (pong or otherwise)
    /// after sending a ping before declaring the socket dead.
    private static let pongTimeout: TimeInterval = 10
    /// Monotonic timestamp of the last frame we received. Used by the
    /// keepalive loop to decide whether the connection is silently dead.
    private var lastReceiveAt: Date = .distantPast
    /// NWPathMonitor that drives an immediate reconnect when the network
    /// path goes from unsatisfied → satisfied (e.g. headset wakes from
    /// sleep, Wi-Fi reattaches).
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied: Bool = true
    /// Set when the server rejects the upgrade with 1008. Suppresses
    /// further reconnect attempts so we don't spam the server with
    /// requests that will keep failing for the same reason.
    private var halted: Bool = false

    var onMessage: ((RemoteWSMessage) -> Void)?
    /// Fires after the first inbound frame arrives on each (re)connection.
    /// The server forgets per-session state (channel binding via
    /// `slideshowConfig`) when the socket dies, so the viewer must replay
    /// it here or the channel will never push `playback` frames again.
    var onConnected: (() -> Void)?

    func connect(wsEndpoint: String, deviceId: String) {
        guard !wsEndpoint.isEmpty, let url = URL(string: wsEndpoint) else { return }

        self.wsURL = url
        self.initialDeviceId = deviceId
        // A new connect attempt clears any prior halt — caller may have
        // updated the access token in config and is asking us to retry.
        self.halted = false
        startPathMonitor()

        doConnect()
    }

    /// Fresh URLSession per connect attempt. Reusing across reconnects
    /// lets stale HTTP/2 multiplex state and connection-pool entries
    /// survive an EPIPE — symptom: the new `webSocketTask` resumes, the
    /// server logs the upgrade, but no frames ever reach our receive
    /// loop. Ephemeral config also avoids any cookie/credential carry.
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }

    /// Force an immediate reconnect attempt, cancelling any sleeping
    /// backoff. Called by viewers when returning to the foreground so
    /// recovery doesn't have to wait out the exponential delay.
    func forceReconnectNow() {
        if halted { return }
        guard wsURL != nil, session != nil else { return }
        // Always tear down — `isConnected`/`webSocketTask` can both look
        // healthy while the underlying TCP path is dead (classic iOS
        // sleep/wake zombie socket: `receive()` doesn't error until the
        // OS finally tries to deliver a frame, which can take minutes).
        // Probing with a ping isn't enough either, since the server's
        // pong would race the reconnect we want anyway.
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        retryCount = 0
        AppLogger.remoteViewer.info("WebSocket force reconnect requested")
        doConnect()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        retryCount = 0
        stopPathMonitor()
        session?.invalidateAndCancel()
        session = nil
    }

    /// Notify the server about a device's active/background state
    /// (used by the RoboFrame server for in-home location tracking).
    func sendVisibilityChange(deviceId: String, visible: Bool) {
        sendJSON([
            "action": "visibility",
            "payload": ["deviceId": deviceId, "visible": visible]
        ])
    }

    func sendBlock(postId: Int) {
        sendJSON(["action": "block", "payload": ["id": postId]])
    }

    /// displaySync claims the merge driver role: `enabled: true` makes this
    /// session the source of truth for every channel — every connected display
    /// mirrors the driver's playback regardless of its own deviceId.
    /// `enabled: false` releases the merge and each channel resumes its own
    /// cadence. Server broadcasts a new `playback` frame in response.
    func sendDisplaySync(enabled: Bool) {
        sendJSON(["action": "displaySync", "payload": ["enabled": enabled]])
    }

    /// Required after WS open: join this session to the channel for `deviceId`.
    /// Two sessions on the same deviceId share a channel and lockstep on the
    /// same image. Mod tags ride along so the orchestrator's first refill
    /// query already includes them — without that the initial query is
    /// discarded when a separate setModTags arrives a few ms later.
    func sendSlideshowConfig(deviceId: String, interval: Int, width: Int, height: Int, bright: Bool, convert: Bool, ratio: String? = nil, modTags: [String] = []) {
        var payload: [String: Any] = [
            "deviceId": deviceId,
            "interval": interval,
            "width": width,
            "height": height,
            "bright": bright,
            "convert": convert,
            "modTags": modTags,
        ]
        if let ratio { payload["ratio"] = ratio }
        sendJSON(["action": "slideshowConfig", "payload": payload])
    }

    /// Client-supplied modifier tags. The orchestrator folds them into this
    /// channel's DuckDB query (last-write-wins among same-channel sessions).
    func sendSetModTags(tags: [String]) {
        sendJSON(["action": "setModTags", "payload": ["tags": tags]])
    }

    /// Switch the active tag list catalog index. Server is authoritative
    /// (broadcasts `currentTagList` to every client), so this is how a
    /// session asks every channel to retag.
    func sendSetTagList(listNumber: Int) {
        sendJSON(["action": "setTagList", "payload": ["listNumber": listNumber]])
    }

    /// Ask the server to advance the channel. Any session may call this;
    /// when displaySync is active, the merge driver's channel advances and
    /// every display sees the same new image.
    func sendRequestNext() {
        sendJSON(["action": "requestNext"])
    }

    /// Tell the server we've finished transitioning to `postId`. The
    /// orchestrator's readiness barrier waits for every visible session on
    /// the channel before starting the dwell timer; without this report the
    /// channel rides the 10 s bad-network fallback every cycle, which makes
    /// the effective server cycle ~10 s longer than the configured interval.
    func sendImageReady(postId: Int) {
        sendJSON(["action": "imageReady", "payload": ["id": postId]])
    }

    // MARK: - Private

    private func doConnect() {
        guard let url = wsURL else { return }

        // Always rebuild the session — see makeSession() comment.
        session?.invalidateAndCancel()
        let newSession = makeSession()
        self.session = newSession

        webSocketTask = newSession.webSocketTask(with: url)
        webSocketTask?.resume()
        // Don't flip `isConnected` until the first inbound frame arrives —
        // an in-progress upgrade can look healthy for a long time before
        // failing, and consumers (incl. forceReconnect callers) rely on
        // this flag to mean "the socket is actually carrying traffic."
        isConnected = false
        lastReceiveAt = Date()

        AppLogger.remoteViewer.info("WebSocket connecting to \(url.absoluteString, privacy: .private)")

        // RoboFrame's rpcserver pushes `tagLists`, `blocked`, and `currentTagList`
        // automatically on connect — no need to request them. We just announce visibility.
        if !initialDeviceId.isEmpty {
            sendVisibilityChange(deviceId: initialDeviceId, visible: true)
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        keepaliveTask = Task { [weak self] in
            await self?.keepaliveLoop()
        }
    }

    private func receiveLoop() async {
        AppLogger.remoteViewer.info("WebSocket receive loop entered")
        defer { AppLogger.remoteViewer.info("WebSocket receive loop exited") }
        let myTask = webSocketTask
        while !Task.isCancelled {
            guard let task = myTask, task === webSocketTask else {
                AppLogger.remoteViewer.info("WebSocket receive loop: task no longer current, exiting")
                break
            }

            do {
                let message = try await task.receive()
                lastReceiveAt = Date()
                if !isConnected {
                    // First frame from the upgraded connection — promote
                    // to fully-connected and reset backoff so the next
                    // failure starts fresh.
                    isConnected = true
                    retryCount = 0
                    onConnected?()
                }
                switch message {
                case .string(let text):
                    handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                logWebSocketFailure(error, task: task)
                isConnected = false
                keepaliveTask?.cancel()
                keepaliveTask = nil
                // The broker closes unauthenticated upgrades with 1008
                // (policy violation). Reconnecting won't fix a bad token,
                // so halt the loop and surface the reason once.
                if task.closeCode == .policyViolation {
                    halted = true
                    let reasonStr: String = {
                        if let data = task.closeReason, let s = String(data: data, encoding: .utf8), !s.isEmpty {
                            return s
                        }
                        return "invalid token"
                    }()
                    let msg = "Server rejected WebSocket: \(reasonStr). Check the Access Token in viewer settings."
                    AppLogger.remoteViewer.error("\(msg, privacy: .public)")
                    onMessage?(.fatalAuthError(reason: msg))
                    break
                }
                scheduleReconnect()
                break
            }
        }
    }

    /// Dump enough detail when a receive fails (handshake rejection, server
    /// closed mid-stream, etc.) that we can tell whether nginx returned a
    /// 4xx/5xx, sent a non-Upgrade response, or the TLS layer was unhappy.
    private func logWebSocketFailure(_ error: Error, task: URLSessionWebSocketTask) {
        let nsError = error as NSError
        var detail = "domain=\(nsError.domain) code=\(nsError.code) desc=\(error.localizedDescription)"
        if let urlError = error as? URLError {
            detail += " urlErrorCode=\(urlError.code.rawValue)"
            if let response = urlError.userInfo[NSURLErrorFailingURLPeerTrustErrorKey] {
                detail += " peerTrust=\(response)"
            }
            if let failing = urlError.failureURLString {
                detail += " url=\(failing)"
            }
        }
        if task.closeCode != .invalid {
            detail += " closeCode=\(task.closeCode.rawValue)"
        }
        if let reason = task.closeReason, let reasonStr = String(data: reason, encoding: .utf8), !reasonStr.isEmpty {
            detail += " closeReason=\(reasonStr)"
        }
        AppLogger.remoteViewer.warning("WebSocket receive error: \(detail, privacy: .public)")
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            AppLogger.remoteViewer.debug("WS rx (unparseable): \(text.prefix(200), privacy: .public)")
            return
        }

        let payload = json["payload"]
        AppLogger.remoteViewer.debug("WS rx action=\(action, privacy: .public)")

        switch action {
        case "tagLists":
            // Server-pushed canonical tag list catalog. Accepts either
            // [[String]] (canonical) or [String] (legacy: space-separated).
            if let nested = payload as? [[String]] {
                onMessage?(.tagLists(lists: nested))
            } else if let flat = payload as? [String] {
                let split = flat.map { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
                onMessage?(.tagLists(lists: split))
            }

        case "currentTagList":
            if let dict = payload as? [String: Any],
               let listNumber = dict["listNumber"] as? Int {
                onMessage?(.currentTagList(index: listNumber))
            }

        case "playVideo", "stopVideo":
            // Video RPC commands are intentionally ignored — they're meant
            // for physical kiosk displays, not visionOS windows.
            break

        case "showText":
            if let dict = payload as? [String: Any],
               let text = dict["text"] as? String {
                let bgColor = dict["bgColorHex"] as? String ?? "#000000"
                let imageUrl = dict["imageUrl"] as? String
                onMessage?(.showText(text: text, bgColorHex: bgColor, imageUrl: imageUrl))
            }

        case "dismissText":
            onMessage?(.dismissText)

        case "playAudio":
            if let dict = payload as? [String: Any],
               let urlStr = dict["url"] as? String,
               let url = URL(string: urlStr) {
                onMessage?(.playAudio(url: url))
            }

        case "stopAudio":
            onMessage?(.stopAudio)

        case "update":
            if let dict = payload as? [String: Any],
               let entity = dict["entity"] as? String,
               let state = dict["state"] as? String {
                let attrs = dict["attributes"] as? [String: Any]
                let friendlyName = attrs?["friendly_name"] as? String ?? entity
                let unit = attrs?["unit_of_measurement"] as? String ?? ""

                if state == "unavailable" {
                    if var existing = sensorData[entity] {
                        existing.isUnavailable = true
                        existing.lastKnownState = existing.state
                        sensorData[entity] = existing
                    }
                } else {
                    sensorData[entity] = HASensorReading(
                        entityId: entity,
                        state: state,
                        friendlyName: friendlyName,
                        unitOfMeasurement: unit
                    )
                }
                onMessage?(.sensorUpdate(entityId: entity, state: state, friendlyName: friendlyName, unit: unit))
            }

        case "refresh":
            onMessage?(.refresh)

        case "playback":
            if let dict = payload as? [String: Any] {
                onMessage?(.playback(payload: dict))
            }

        case "ping":
            // Server-initiated liveness probe. Reply immediately so it
            // doesn't decide we're a dead client.
            sendJSON(["action": "pong"])

        case "pong":
            // Reply to our own keepalive ping. `lastReceiveAt` already
            // updated in the receive loop; nothing more to do.
            break

        default:
            AppLogger.remoteViewer.debug("Unknown WS action: \(action, privacy: .public)")
        }
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }

        webSocketTask?.send(.string(text)) { error in
            if let error {
                AppLogger.remoteViewer.warning("WebSocket send error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Periodic application-level ping. The RoboFrame server replies with
    /// `{action: "pong"}` (see protocol.md). We don't match individual
    /// pings to pongs — any inbound frame counts as liveness, so the
    /// timeout check is "did *anything* arrive within pongTimeout of the
    /// last ping send?". On timeout we force a reconnect; this is the
    /// primary detector for half-open sockets after sleep/wake.
    private func keepaliveLoop() async {
        AppLogger.remoteViewer.info("WebSocket keepalive loop entered")
        defer { AppLogger.remoteViewer.info("WebSocket keepalive loop exited") }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.pingInterval))
            if Task.isCancelled { return }
            guard webSocketTask != nil else { return }
            let sentAt = Date()
            AppLogger.remoteViewer.debug("WebSocket sending keepalive ping")
            sendJSON(["action": "ping"])
            try? await Task.sleep(for: .seconds(Self.pongTimeout))
            if Task.isCancelled { return }
            if lastReceiveAt < sentAt {
                AppLogger.remoteViewer.warning("WebSocket pong timeout (last rx \(self.lastReceiveAt.timeIntervalSinceNow, privacy: .public)s ago) — forcing reconnect")
                forceReconnectNow()
                return
            }
        }
    }

    private func startPathMonitor() {
        if pathMonitor != nil { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let satisfied = (path.status == .satisfied)
                let wasSatisfied = self.lastPathSatisfied
                self.lastPathSatisfied = satisfied
                // Only react to unsatisfied → satisfied transitions. The
                // initial callback is usually `.satisfied` and we don't
                // want to tear down a perfectly good connection on launch.
                if satisfied, !wasSatisfied {
                    AppLogger.remoteViewer.info("Network path satisfied — forcing WebSocket reconnect")
                    self.forceReconnectNow()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "RemoteWebSocketClient.path"))
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func scheduleReconnect() {
        if halted { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let delay = min(pow(2.0, Double(retryCount)), Self.maxRetryDelay)
            retryCount += 1
            AppLogger.remoteViewer.info("WebSocket reconnecting in \(delay, privacy: .public)s")
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, !halted else { return }
            doConnect()
        }
    }
}
