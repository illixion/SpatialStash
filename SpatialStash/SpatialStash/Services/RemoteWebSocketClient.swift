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

/// One logical viewer session multiplexed onto a shared connection.
/// Per-session onMessage receives `playback` frames addressed to this
/// sessionId plus all connection-wide frames (tagLists, currentTagList,
/// sensors, effect frames). onConnected fires after the underlying
/// connection produces its first inbound frame on every (re)connection
/// — replay slideshowConfig from there.
@MainActor
final class RemoteWSSessionHandlers {
    var onMessage: ((RemoteWSMessage) -> Void)?
    var onConnected: (() -> Void)?
}

@MainActor
@Observable
class RemoteWebSocketClient {
    var sensorData: [String: HASensorReading] = [:]
    var isConnected: Bool = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var wsURL: URL?
    private var reconnectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var retryCount: Int = 0
    /// Wall-clock timestamp of the last `doConnect` call. Used to floor
    /// the reconnect interval — without this, when the new socket fails
    /// inside a millisecond (ENOTCONN during sleep / interface flap), the
    /// retry firehose hammers the server even if `retryCount` is climbing.
    private var lastConnectAttemptAt: Date = .distantPast
    private static let minRetryDelay: TimeInterval = 2
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

    /// Multiplexing — multiple viewer windows can share one underlying
    /// connection, each addressed by a sessionId. `playback` frames carry
    /// a `sessionIds` array and are routed to matching entries here;
    /// connection-wide frames (tagLists, sensors, effects) fan out to
    /// every entry. Refcount: when the last session detaches, the
    /// connection is torn down.
    private var sessions: [String: RemoteWSSessionHandlers] = [:]

    /// Attach a logical viewer session to this connection. The connection
    /// is established lazily on the first attach. Returns the handlers
    /// record so the caller can wire its onMessage/onConnected closures.
    /// `wsEndpoint` is honored only on the first attach; subsequent
    /// attaches reuse the existing connection regardless of endpoint.
    @discardableResult
    func attachSession(sessionId: String, wsEndpoint: String) -> RemoteWSSessionHandlers {
        if let existing = sessions[sessionId] { return existing }
        let entry = RemoteWSSessionHandlers()
        sessions[sessionId] = entry
        if wsURL == nil, !wsEndpoint.isEmpty, let url = URL(string: wsEndpoint) {
            self.wsURL = url
            self.halted = false
            startPathMonitor()
            doConnect()
        } else if isConnected {
            // Connection already alive — fire onConnected for late joiners
            // immediately (after the caller wires the closure; they'll do
            // that synchronously after this returns).
            DispatchQueue.main.async { [weak entry] in
                entry?.onConnected?()
            }
        }
        return entry
    }

    /// Detach a session. Sends a best-effort `sessionEnd` to the server
    /// so the orchestrator can drop the channel binding without waiting
    /// for the channel grace timeout. Returns the number of remaining
    /// attached sessions; zero means the caller should call `disconnect()`
    /// to release the underlying connection.
    @discardableResult
    func detachSession(sessionId: String) -> Int {
        guard sessions.removeValue(forKey: sessionId) != nil else { return sessions.count }
        if isConnected {
            sendJSON(["sessionId": sessionId, "action": "sessionEnd"])
        }
        return sessions.count
    }

    var attachedSessionCount: Int { sessions.count }

    private func broadcastToSessions(_ message: RemoteWSMessage) {
        for entry in sessions.values { entry.onMessage?(message) }
    }

    private func routeToSessions(_ message: RemoteWSMessage, sessionIds: [String]) {
        for id in sessionIds {
            sessions[id]?.onMessage?(message)
        }
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

    /// Probe the socket with a JSON ping; if no inbound traffic arrives
    /// within `timeout` seconds, force a reconnect. Use this on
    /// scene-phase wakes instead of unconditionally reconnecting — a
    /// healthy connection answers the ping with a pong (per protocol.md)
    /// and we leave it alone, avoiding spurious displayDisconnect
    /// broadcasts to peer kiosks.
    func probeOrReconnect(timeout: TimeInterval = 3) {
        if halted { return }
        guard wsURL != nil else { return }
        if !isConnected || webSocketTask == nil {
            forceReconnectNow()
            return
        }
        let sentAt = Date()
        AppLogger.remoteViewer.info("WebSocket probe ping (timeout=\(timeout, privacy: .public)s)")
        sendJSON(["action": "ping"])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self else { return }
            if self.lastReceiveAt < sentAt {
                AppLogger.remoteViewer.warning("WebSocket probe timed out — forcing reconnect")
                self.forceReconnectNow()
            }
        }
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
        // Intentionally NOT resetting retryCount here. forceReconnectNow
        // is fired on path-up transitions and scenePhase wakes — neither
        // proves the connection will actually succeed. Resetting here
        // produced a 1 s reconnect storm whenever the socket failed
        // instantly with ENOTCONN: each failure called scheduleReconnect,
        // some other caller fired forceReconnectNow, retryCount went back
        // to 0, and the cycle repeated. retryCount only resets after
        // we've actually received a frame (see receiveLoop).
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
    /// session's channel the source of truth for every channel — every
    /// connected display mirrors the driver's playback regardless of its
    /// own deviceId. `enabled: false` releases the merge.
    func sendDisplaySync(sessionId: String, enabled: Bool) {
        sendJSON(["sessionId": sessionId, "action": "displaySync", "payload": ["enabled": enabled]])
    }

    /// Required after WS open: join this session to the channel for `deviceId`.
    /// Two sessions on the same deviceId share a channel and lockstep on the
    /// same image. Mod tags ride along so the orchestrator's first refill
    /// query already includes them — without that the initial query is
    /// discarded when a separate setModTags arrives a few ms later.
    func sendSlideshowConfig(sessionId: String, deviceId: String, interval: Int, width: Int, height: Int, bright: Bool, convert: Bool, ratio: String? = nil, modTags: [String] = []) {
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
        sendJSON(["sessionId": sessionId, "action": "slideshowConfig", "payload": payload])
    }

    /// Client-supplied modifier tags. The orchestrator folds them into this
    /// channel's DuckDB query (last-write-wins among same-channel sessions).
    func sendSetModTags(sessionId: String, tags: [String]) {
        sendJSON(["sessionId": sessionId, "action": "setModTags", "payload": ["tags": tags]])
    }

    /// Switch the active tag list catalog index for the sender's channel.
    /// Per-channel — the server scopes the change to the deviceId behind
    /// this session, so peer channels keep their own list.
    func sendSetTagList(sessionId: String, listNumber: Int) {
        sendJSON(["sessionId": sessionId, "action": "setTagList", "payload": ["listNumber": listNumber]])
    }

    /// Ask the server to advance the channel. Any session may call this;
    /// when displaySync is active, the merge driver's channel advances.
    func sendRequestNext(sessionId: String) {
        sendJSON(["sessionId": sessionId, "action": "requestNext"])
    }

    /// Tell the server we've finished transitioning to `postId`. The
    /// orchestrator's readiness barrier waits for every visible session on
    /// the channel before starting the dwell timer.
    func sendImageReady(sessionId: String, postId: Int) {
        sendJSON(["sessionId": sessionId, "action": "imageReady", "payload": ["id": postId]])
    }

    // MARK: - Private

    private func doConnect() {
        guard let url = wsURL else { return }

        // Reuse the URLSession across reconnects. An earlier version of
        // this code rebuilt the session on every doConnect to clear stale
        // HTTP/2 multiplex state, but that produced an even worse failure
        // mode: invalidating the old session and immediately resuming a
        // new task on a freshly-built session races kernel socket teardown,
        // and the new task throws ENOTCONN inside a millisecond. That's
        // the storm the user saw — instant fail, retry, instant fail.
        // WebSocket tasks are HTTP/1.1 (no multiplexing) so there's no
        // pool state to worry about; the previous fix was solving a
        // problem that doesn't apply here.
        if session == nil {
            session = makeSession()
        }
        guard let session else { return }

        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        lastConnectAttemptAt = Date()
        // Don't flip `isConnected` until the first inbound frame arrives —
        // an in-progress upgrade can look healthy for a long time before
        // failing, and consumers (incl. forceReconnect callers) rely on
        // this flag to mean "the socket is actually carrying traffic."
        isConnected = false
        lastReceiveAt = Date()

        AppLogger.remoteViewer.info("WebSocket connecting to \(url.absoluteString, privacy: .private)")

        // RoboFrame's rpcserver pushes `tagLists` and `currentTagList`
        // automatically on connect — no need to request them. Sessions
        // announce their own visibility from `onConnected`.

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
                    // failure starts fresh. Notify every attached session
                    // so each one re-sends slideshowConfig (the server
                    // forgets per-session channel binding when a socket
                    // dies).
                    isConnected = true
                    retryCount = 0
                    for entry in sessions.values { entry.onConnected?() }
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
                // If we're not the current task, the connection has
                // already been swapped (forceReconnectNow / disconnect);
                // bail without rescheduling. Otherwise both loops race
                // scheduleReconnect, the second cancels the first's
                // backoff timer, and retryCount effectively never climbs.
                guard task === webSocketTask else {
                    AppLogger.remoteViewer.info("WebSocket stale receive loop exiting (current task swapped)")
                    break
                }
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
                    broadcastToSessions(.fatalAuthError(reason: msg))
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
                broadcastToSessions(.tagLists(lists: nested))
            } else if let flat = payload as? [String] {
                let split = flat.map { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
                broadcastToSessions(.tagLists(lists: split))
            }

        case "currentTagList":
            if let dict = payload as? [String: Any],
               let listNumber = dict["listNumber"] as? Int {
                broadcastToSessions(.currentTagList(index: listNumber))
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
                broadcastToSessions(.showText(text: text, bgColorHex: bgColor, imageUrl: imageUrl))
            }

        case "dismissText":
            broadcastToSessions(.dismissText)

        case "playAudio":
            if let dict = payload as? [String: Any],
               let urlStr = dict["url"] as? String,
               let url = URL(string: urlStr) {
                broadcastToSessions(.playAudio(url: url))
            }

        case "stopAudio":
            broadcastToSessions(.stopAudio)

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
                broadcastToSessions(.sensorUpdate(entityId: entity, state: state, friendlyName: friendlyName, unit: unit))
            }

        case "refresh":
            broadcastToSessions(.refresh)

        case "playback":
            // Session-scoped: route to the sessionIds the server addressed.
            if let dict = payload as? [String: Any] {
                if let ids = json["sessionIds"] as? [String], !ids.isEmpty {
                    routeToSessions(.playback(payload: dict), sessionIds: ids)
                } else {
                    // Defensive fallback (server shouldn't omit sessionIds,
                    // but if it does, deliver to every session so something
                    // renders).
                    broadcastToSessions(.playback(payload: dict))
                }
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
        // If the OS reports the network path as unsatisfied, retrying on
        // a 1 s timer just produces an immediate ENOTCONN (errno 57) on
        // every attempt and burns battery for the entire outage. Park
        // here and let the path monitor's unsatisfied → satisfied
        // callback wake us via forceReconnectNow().
        if !lastPathSatisfied {
            AppLogger.remoteViewer.info("WebSocket reconnect deferred — network path unsatisfied")
            reconnectTask?.cancel()
            reconnectTask = nil
            return
        }
        reconnectTask?.cancel()
        let attempt = retryCount
        retryCount += 1
        // Two flooring rules:
        //  1. Min 2 s between attempts. ENOTCONN can throw inside a
        //     millisecond, and a 1 s loop on top of that hammered the
        //     server hard enough to keep emitting `displayDisconnect`
        //     broadcasts to peer kiosks every cycle.
        //  2. Subtract elapsed-since-last-attempt from the exponential
        //     delay so a long connect (waitsForConnectivity stalled for
        //     20 s before failing) doesn't then add another long sleep
        //     on top.
        let exponential = min(pow(2.0, Double(attempt)), Self.maxRetryDelay)
        let sinceLast = Date().timeIntervalSince(lastConnectAttemptAt)
        let delay = max(Self.minRetryDelay, exponential - sinceLast)
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            AppLogger.remoteViewer.info("WebSocket reconnecting in \(delay, privacy: .public)s (attempt=\(attempt, privacy: .public))")
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, !halted else { return }
            // Re-check the path right before connecting — the path may
            // have flipped during the backoff sleep.
            if !self.lastPathSatisfied {
                AppLogger.remoteViewer.info("WebSocket reconnect aborted — path went unsatisfied during backoff")
                return
            }
            doConnect()
        }
    }
}
