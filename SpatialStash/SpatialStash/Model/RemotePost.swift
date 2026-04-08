/*
 Spatial Stash - Remote Post Model

 Represents an image post from the RoboFrame API.
 */

import Foundation

struct RemotePost: Codable, Identifiable, Hashable {
    let _id: Int
    let file_ext: String
    let tags: [String]
    let rating: String?
    let image_width: Int?
    let image_height: Int?
    let fav_count: Int?
    let md5: String?
    let parent_id: Int?
    let score: Int?
    let ratio: Double?
    let path: String?
    let duration: Double?

    var id: Int { _id }

    private enum CodingKeys: String, CodingKey {
        case _id, file_ext, tags, rating, image_width, image_height
        case fav_count, md5, parent_id, score, ratio, path, duration
    }
}

struct RemoteSearchResponse: Codable {
    let results: [RemotePost]
    let nextCursor: AnyCursor?

    /// The API returns nextCursor as either a number or string depending on context.
    enum AnyCursor: Codable, Hashable {
        case number(Double)
        case string(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let doubleVal = try? container.decode(Double.self) {
                self = .number(doubleVal)
            } else if let strVal = try? container.decode(String.self) {
                self = .string(strVal)
            } else {
                throw DecodingError.typeMismatch(
                    AnyCursor.self,
                    .init(codingPath: decoder.codingPath, debugDescription: "Expected number or string for cursor")
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let v): try container.encode(v)
            case .string(let v): try container.encode(v)
            }
        }

        var stringValue: String {
            switch self {
            case .number(let v):
                // Preserve full precision to match server expectations
                return v == v.rounded(.towardZero) && v < 1e15
                    ? String(format: "%.0f", v)
                    : String(v)
            case .string(let v): return v
            }
        }
    }
}
