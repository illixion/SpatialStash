/*
 Spatial Stash - Stash API Client

 GraphQL client for communicating with Stash server.
 */

import Foundation

/// Configuration for Stash server connection
struct StashServerConfig {
    var serverURL: URL
    var apiKey: String?

    static var `default`: StashServerConfig {
        StashServerConfig(
            serverURL: URL(string: "http://localhost:9999")!,
            apiKey: nil
        )
    }
}

/// GraphQL response wrapper
struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

struct GraphQLError: Decodable, Error {
    let message: String
    let locations: [GraphQLErrorLocation]?
    let path: [String]?
}

struct GraphQLErrorLocation: Decodable {
    let line: Int
    let column: Int
}

/// Stash API Client for GraphQL queries
actor StashAPIClient {
    private var config: StashServerConfig
    private let session: URLSession

    init(config: StashServerConfig = .default) {
        self.config = config
        self.session = URLSession.shared
    }

    func updateConfig(_ newConfig: StashServerConfig) {
        self.config = newConfig
    }

    var graphQLEndpoint: URL {
        config.serverURL.appendingPathComponent("graphql")
    }

    // MARK: - Generic GraphQL Query

    func query<T: Decodable>(_ query: String, variables: [String: Any]? = nil) async throws -> T {
        let endpoint = graphQLEndpoint
        print("[StashAPI] Making request to: \(endpoint)")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = config.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            print("[StashAPI] Using API key authentication")
        }

        var body: [String: Any] = ["query": query]
        if let variables = variables {
            body["variables"] = variables
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        print("[StashAPI] Request body: \(String(data: bodyData, encoding: .utf8) ?? "nil")")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[StashAPI] Invalid response type")
                throw StashAPIError.invalidResponse
            }

            print("[StashAPI] Response status: \(httpResponse.statusCode)")

            guard (200...299).contains(httpResponse.statusCode) else {
                print("[StashAPI] HTTP error: \(httpResponse.statusCode)")
                if let responseString = String(data: data, encoding: .utf8) {
                    print("[StashAPI] Response body: \(responseString)")
                }
                throw StashAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            if let responseString = String(data: data, encoding: .utf8) {
                print("[StashAPI] Response: \(responseString.prefix(500))...")
            }

            let decoder = JSONDecoder()
            let graphQLResponse = try decoder.decode(GraphQLResponse<T>.self, from: data)

            if let errors = graphQLResponse.errors, !errors.isEmpty {
                print("[StashAPI] GraphQL errors: \(errors.map { $0.message })")
                throw StashAPIError.graphQLErrors(errors)
            }

            guard let responseData = graphQLResponse.data else {
                print("[StashAPI] No data in response")
                throw StashAPIError.noData
            }

            print("[StashAPI] Query successful")
            return responseData
        } catch let error as StashAPIError {
            throw error
        } catch {
            print("[StashAPI] Network error: \(error)")
            throw error
        }
    }

    // MARK: - Image Queries

    struct FindImagesResponse: Decodable {
        let findImages: FindImagesResult
    }

    struct FindImagesResult: Decodable {
        let count: Int
        let images: [StashImage]
    }

    struct StashImage: Decodable {
        let id: String
        let title: String?
        let paths: StashImagePaths
        let files: [StashImageFile]?
    }

    struct StashImagePaths: Decodable {
        let thumbnail: String?
        let image: String?
    }

    struct StashImageFile: Decodable {
        let width: Int?
        let height: Int?
    }

    func findImages(page: Int, perPage: Int, query: String? = nil) async throws -> FindImagesResult {
        try await findImages(page: page, perPage: perPage, filter: nil, query: query)
    }

    func findImages(page: Int, perPage: Int, filter: ImageFilterCriteria?, query: String? = nil) async throws -> FindImagesResult {
        let graphQLQuery = """
        query FindImages($filter: FindFilterType, $image_filter: ImageFilterType) {
            findImages(filter: $filter, image_filter: $image_filter) {
                count
                images {
                    id
                    title
                    paths {
                        thumbnail
                        image
                    }
                    files {
                        width
                        height
                    }
                }
            }
        }
        """

        // Build FindFilterType
        var filterVariables: [String: Any] = [
            "page": page,
            "per_page": perPage
        ]

        // Apply sort from filter or use defaults
        if let filter = filter {
            filterVariables["sort"] = filter.sortField.rawValue
            filterVariables["direction"] = filter.sortDirection.rawValue

            // Search term goes in FindFilterType.q
            if !filter.searchTerm.isEmpty {
                filterVariables["q"] = filter.searchTerm
            }
        } else {
            filterVariables["sort"] = "created_at"
            filterVariables["direction"] = "DESC"

            if let query = query, !query.isEmpty {
                filterVariables["q"] = query
            }
        }

        var variables: [String: Any] = ["filter": filterVariables]

        // Build ImageFilterType if we have filter criteria
        if let filter = filter, filter.hasActiveFilters {
            var imageFilter: [String: Any] = [:]

            // Gallery filter
            if !filter.galleryIds.isEmpty {
                imageFilter["galleries"] = [
                    "value": filter.galleryIds,
                    "modifier": filter.galleryModifier.rawValue
                ]
            }

            // O Count filter
            if filter.oCountEnabled {
                var oCountCriterion: [String: Any] = [
                    "modifier": filter.oCountModifier.rawValue
                ]
                if filter.oCountModifier.requiresRange {
                    oCountCriterion["value"] = filter.oCountRange.min ?? 0
                    oCountCriterion["value2"] = filter.oCountRange.max ?? 0
                } else if filter.oCountModifier.requiresValue, let value = filter.oCountValue {
                    oCountCriterion["value"] = value
                }
                imageFilter["o_counter"] = oCountCriterion
            }

            // Rating filter (uses rating100 in API, 1-100 scale)
            if filter.ratingEnabled {
                var ratingCriterion: [String: Any] = [
                    "modifier": filter.ratingModifier.rawValue
                ]
                if filter.ratingModifier.requiresRange {
                    ratingCriterion["value"] = ImageFilterCriteria.ratingToAPI(filter.ratingRange.min ?? 1)
                    ratingCriterion["value2"] = ImageFilterCriteria.ratingToAPI(filter.ratingRange.max ?? 5)
                } else if filter.ratingModifier.requiresValue, let value = filter.ratingValue {
                    ratingCriterion["value"] = ImageFilterCriteria.ratingToAPI(value)
                }
                imageFilter["rating100"] = ratingCriterion
            }

            // Tags filter
            if !filter.tagIds.isEmpty {
                imageFilter["tags"] = [
                    "value": filter.tagIds,
                    "modifier": filter.tagModifier.rawValue
                ]
            }

            if !imageFilter.isEmpty {
                variables["image_filter"] = imageFilter
            }
        }

        let response: FindImagesResponse = try await self.query(graphQLQuery, variables: variables)
        return response.findImages
    }

    // MARK: - Gallery Queries (for autocomplete)

    struct FindGalleriesResponse: Decodable {
        let findGalleries: FindGalleriesResult
    }

    struct FindGalleriesResult: Decodable {
        let count: Int
        let galleries: [StashGallery]
    }

    struct StashGallery: Decodable {
        let id: String
        let title: String?
        let folder: StashGalleryFolder?
        let files: [StashGalleryFile]?
    }

    struct StashGalleryFolder: Decodable {
        let path: String
    }

    struct StashGalleryFile: Decodable {
        let path: String
    }

    func findGalleries(query: String? = nil, page: Int = 1, perPage: Int = 25) async throws -> FindGalleriesResult {
        let graphQLQuery = """
        query FindGalleries($filter: FindFilterType) {
            findGalleries(filter: $filter) {
                count
                galleries {
                    id
                    title
                    folder {
                        path
                    }
                    files {
                        path
                    }
                }
            }
        }
        """

        var filterVariables: [String: Any] = [
            "page": page,
            "per_page": perPage,
            "sort": "title",
            "direction": "ASC"
        ]

        if let query = query, !query.isEmpty {
            filterVariables["q"] = query
        }

        let response: FindGalleriesResponse = try await self.query(graphQLQuery, variables: ["filter": filterVariables])
        return response.findGalleries
    }

    // MARK: - Tag Queries (for autocomplete)

    struct FindTagsResponse: Decodable {
        let findTags: FindTagsResult
    }

    struct FindTagsResult: Decodable {
        let count: Int
        let tags: [StashTag]
    }

    struct StashTag: Decodable {
        let id: String
        let name: String
    }

    func findTags(query: String? = nil, page: Int = 1, perPage: Int = 25) async throws -> FindTagsResult {
        let graphQLQuery = """
        query FindTags($filter: FindFilterType) {
            findTags(filter: $filter) {
                count
                tags {
                    id
                    name
                }
            }
        }
        """

        var filterVariables: [String: Any] = [
            "page": page,
            "per_page": perPage,
            "sort": "name",
            "direction": "ASC"
        ]

        if let query = query, !query.isEmpty {
            filterVariables["q"] = query
        }

        let response: FindTagsResponse = try await self.query(graphQLQuery, variables: ["filter": filterVariables])
        return response.findTags
    }

    // MARK: - Scene/Video Queries

    struct FindScenesResponse: Decodable {
        let findScenes: FindScenesResult
    }

    struct FindScenesResult: Decodable {
        let count: Int
        let scenes: [StashScene]
    }

    struct StashScene: Decodable {
        let id: String
        let title: String?
        let details: String?
        let date: String?
        let paths: StashScenePaths
        let files: [StashSceneFile]?
    }

    struct StashScenePaths: Decodable {
        let screenshot: String?
        let stream: String?
    }

    struct StashSceneFile: Decodable {
        let width: Int?
        let height: Int?
        let duration: Double?
    }

    func findScenes(page: Int, perPage: Int, query: String? = nil) async throws -> FindScenesResult {
        let graphQLQuery = """
        query FindScenes($filter: FindFilterType) {
            findScenes(filter: $filter) {
                count
                scenes {
                    id
                    title
                    details
                    date
                    paths {
                        screenshot
                        stream
                    }
                    files {
                        width
                        height
                        duration
                    }
                }
            }
        }
        """

        var filterVariables: [String: Any] = [
            "page": page,
            "per_page": perPage,
            "sort": "created_at",
            "direction": "DESC"
        ]

        if let query = query, !query.isEmpty {
            filterVariables["q"] = query
        }

        let variables: [String: Any] = ["filter": filterVariables]

        let response: FindScenesResponse = try await self.query(graphQLQuery, variables: variables)
        return response.findScenes
    }
}

/// Errors that can occur when using the Stash API
enum StashAPIError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case graphQLErrors([GraphQLError])
    case noData
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .graphQLErrors(let errors):
            return "GraphQL errors: \(errors.map { $0.message }.joined(separator: ", "))"
        case .noData:
            return "No data in response"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        }
    }
}
