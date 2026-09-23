/*
 Hypnos - the Atmos Objects plugin's endpoints

   GET /AtmosObjects/{itemId}/Video                 index (segment start times, range info)
   GET /AtmosObjects/{itemId}/Video/Init            init segment
   GET /AtmosObjects/{itemId}/Video/Segments/{n}    one keyframe interval, in film time
   GET /AtmosObjects/{itemId}/Scene?startSeconds=T  Atmos layout (422: no objects)
   GET /AtmosObjects/{itemId}/Segments/{n}/Events   positions and gains for audio segment n
   GET /AtmosObjects/{itemId}/Segments/{n}/{g}      FLAC channel group g of audio segment n

 See JellyfinPlugin/README.md. Segments carry the film's own timestamps, so
 segment n's first frame presents at `segmentStarts[n]` in the same time base
 as the audio scene's `startSeconds`.
 */

import Foundation

public struct FilmVideoIndex: Decodable, Sendable {
    public let segmentStarts: [Double]
    public let durationSeconds: Double
    public let codec: String
    public let videoRange: String
    public let dvProfile: Int?
    public let dolbyVision: Bool

    /// The segment whose interval contains `seconds`.
    public func segment(containing seconds: Double) -> Int {
        var low = 0, high = segmentStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segmentStarts[mid] <= seconds { low = mid } else { high = mid - 1 }
        }
        return max(0, low)
    }
}

public enum FilmServerError: Error, LocalizedError {
    case http(path: String, status: Int)

    public var errorDescription: String? {
        switch self {
        case .http(let path, let status): "\(path): HTTP \(status)"
        }
    }
}

public struct FilmServerClient: Sendable {
    public let baseURL: URL
    public let token: String
    public let itemID: String

    public init(baseURL: URL, token: String, itemID: String) {
        self.baseURL = baseURL
        self.token = token
        self.itemID = itemID
    }

    public func videoIndex() async throws -> FilmVideoIndex {
        try JSONDecoder().decode(FilmVideoIndex.self, from: await get("Video"))
    }

    public func videoInit() async throws -> Data {
        try await get("Video/Init")
    }

    public func videoSegment(_ n: Int) async throws -> Data {
        try await get("Video/Segments/\(n)")
    }

    /// The Atmos scene layout, starting a server decode at `startSeconds` if
    /// nothing is cached. Nil when the item has no Atmos objects (HTTP 422).
    public func audioScene(startSeconds: Double) async throws -> AtmosScene? {
        do {
            let data = try await get("Scene", query: [URLQueryItem(name: "startSeconds", value: String(format: "%.3f", startSeconds))])
            return try JSONDecoder().decode(AtmosScene.self, from: data)
        } catch FilmServerError.http(_, 422) {
            return nil
        }
    }

    func audioEvents(segment: Int) async throws -> [AtmosScene.Event] {
        try JSONDecoder().decode([AtmosScene.Event].self, from: await get("Segments/\(segment)/Events"))
    }

    func audioSegment(_ segment: Int, group: Int) async throws -> Data {
        try await get("Segments/\(segment)/\(group)")
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var url = baseURL.appending(path: "AtmosObjects/\(itemID)/\(path)")
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FilmServerError.http(path: path, status: code)
        }
        return data
    }
}
