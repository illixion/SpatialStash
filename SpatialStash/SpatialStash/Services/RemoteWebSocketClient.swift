/*
 Spatial Stash - Remote WebSocket Client

 Manages WebSocket connection for real-time control, sensor data,
 and cross-device synchronization with the RoboFrame server.
 */

import Foundation
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
    case blocked(posts: [Int], tags: [String])
    case displayState(isOn: Bool)
    case currentTagList(index: Int)
    case playVideo(url: URL)
    case stopVideo
    case showText(text: String, bgColorHex: String, imageUrl: String?)
    case dismissText
    case sensorUpdate(entityId: String, state: String, friendlyName: String, unit: String)
    case refresh
    case displaySync(payload: [String: Any])
}

@MainActor
@Observable
class RemoteWebSocketClient {
    var sensorData: [String: HASensorReading] = [:]
    var isDisplayOn: Bool = true
    var isConnected: Bool = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var wsURL: URL?
    private var deviceId: String = ""
    private var reconnectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var retryCount: Int = 0
    private static let maxRetryDelay: TimeInterval = 30

    var onMessage: ((RemoteWSMessage) -> Void)?

    func connect(wsEndpoint: String, deviceId: String) {
        guard !wsEndpoint.isEmpty, let url = URL(string: wsEndpoint) else { return }

        self.wsURL = url
        self.deviceId = deviceId
        self.session = URLSession(configuration: .default)

        doConnect()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        retryCount = 0
    }

    func sendVisibilityChange(visible: Bool) {
        sendJSON([
            "action": "getDisplayState",
            "payload": ["target": deviceId]
        ])
    }

    func sendBlock(postId: Int) {
        sendJSON(["action": "block", "payload": postId])
    }

    func sendGetBlocked() {
        sendJSON(["action": "getBlocked"])
    }

    func sendDisplaySync(currentPost: (id: Int, url: String)?, nextPost: (id: Int, url: String)?, currentList: Int?, dbCursor: String?) {
        var payload: [String: Any] = [:]
        if let currentPost {
            payload["currentPost"] = ["id": currentPost.id, "url": currentPost.url]
        }
        if let nextPost {
            payload["nextPost"] = ["id": nextPost.id, "url": nextPost.url]
        }
        if let currentList {
            payload["currentList"] = currentList
        }
        if let dbCursor {
            payload["dbCursor"] = dbCursor
        }
        sendJSON(["action": "displaySync", "payload": payload])
    }

    // MARK: - Private

    private func doConnect() {
        guard let url = wsURL, let session else { return }

        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        isConnected = true
        retryCount = 0

        AppLogger.remoteViewer.info("WebSocket connecting to \(url.absoluteString, privacy: .private)")

        // Request initial data
        sendGetBlocked()
        if !deviceId.isEmpty {
            sendJSON(["action": "getDisplayState", "payload": ["target": deviceId]])
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let task = webSocketTask else { break }

            do {
                let message = try await task.receive()
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
                AppLogger.remoteViewer.warning("WebSocket receive error: \(error.localizedDescription, privacy: .public)")
                isConnected = false
                scheduleReconnect()
                break
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            return
        }

        let payload = json["payload"]

        switch action {
        case "blocked":
            if let dict = payload as? [String: Any] {
                let posts = (dict["blockedPosts"] as? [Int]) ?? []
                let tags = (dict["blockedTags"] as? [String]) ?? []
                onMessage?(.blocked(posts: posts, tags: tags))
            }

        case "displayState":
            if let dict = payload as? [String: Any],
               let state = dict["state"] {
                let isOn: Bool
                if let boolState = state as? Bool {
                    isOn = boolState
                } else if let strState = state as? String {
                    isOn = strState == "on"
                } else {
                    isOn = true
                }
                isDisplayOn = isOn
                onMessage?(.displayState(isOn: isOn))
            }

        case "currentTagList":
            if let dict = payload as? [String: Any],
               let listNumber = dict["listNumber"] as? Int {
                onMessage?(.currentTagList(index: listNumber))
            }

        case "playVideo":
            if let dict = payload as? [String: Any],
               let urlStr = dict["url"] as? String,
               let url = URL(string: urlStr) {
                onMessage?(.playVideo(url: url))
            }

        case "stopVideo":
            onMessage?(.stopVideo)

        case "showText":
            if let dict = payload as? [String: Any],
               let text = dict["text"] as? String {
                let bgColor = dict["bgColorHex"] as? String ?? "#000000"
                let imageUrl = dict["imageUrl"] as? String
                onMessage?(.showText(text: text, bgColorHex: bgColor, imageUrl: imageUrl))
            }

        case "dismissText":
            onMessage?(.dismissText)

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

        case "displaySync":
            if let dict = payload as? [String: Any] {
                onMessage?(.displaySync(payload: dict))
            }

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

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let delay = min(pow(2.0, Double(retryCount)), Self.maxRetryDelay)
            retryCount += 1
            AppLogger.remoteViewer.info("WebSocket reconnecting in \(delay, privacy: .public)s")
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            doConnect()
        }
    }
}
