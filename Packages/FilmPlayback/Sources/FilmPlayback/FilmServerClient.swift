/*
 Hypnos - the Atmos Objects plugin's video endpoints

   GET /AtmosObjects/{itemId}/Video                 index (segment start times, range info)
   GET /AtmosObjects/{itemId}/Video/Init            init segment
   GET /AtmosObjects/{itemId}/Video/Segments/{n}    one keyframe interval, in film time

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

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: "AtmosObjects/\(itemID)/\(path)"))
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "\(path): HTTP \(code)"])
        }
        return data
    }
}
