/*
 Spatial Stash - Stash API Client

 GraphQL client for communicating with Stash server.
 */

import Foundation
import os

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
        AppLogger.stashAPI.debug("Making request to: \(endpoint, privacy: .private)")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = config.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            AppLogger.stashAPI.debug("Using API key authentication")
        }

        var body: [String: Any] = ["query": query]
        if let variables = variables {
            body["variables"] = variables
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        AppLogger.stashAPI.debug("Request body: \(String(data: bodyData, encoding: .utf8) ?? "nil", privacy: .private)")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                AppLogger.stashAPI.error("Invalid response type")
                throw StashAPIError.invalidResponse
            }

            AppLogger.stashAPI.debug("Response status: \(httpResponse.statusCode, privacy: .public)")

            guard (200...299).contains(httpResponse.statusCode) else {
                AppLogger.stashAPI.error("HTTP error: \(httpResponse.statusCode, privacy: .public)")
                if let responseString = String(data: data, encoding: .utf8) {
                    AppLogger.stashAPI.debug("Response body: \(responseString, privacy: .private)")
                }
                throw StashAPIError.httpError(statusCode: httpResponse.statusCode)
            }

            if let responseString = String(data: data, encoding: .utf8) {
                AppLogger.stashAPI.debug("Response: \(responseString.prefix(500), privacy: .private)...")
            }

            let decoder = JSONDecoder()
            let graphQLResponse = try decoder.decode(GraphQLResponse<T>.self, from: data)

            if let errors = graphQLResponse.errors, !errors.isEmpty {
                AppLogger.stashAPI.error("GraphQL errors: \(errors.map { $0.message }, privacy: .public)")
                throw StashAPIError.graphQLErrors(errors)
            }

            guard let responseData = graphQLResponse.data else {
                AppLogger.stashAPI.error("No data in response")
                throw StashAPIError.noData
            }

            AppLogger.stashAPI.debug("Query successful")
            return responseData
        } catch let error as StashAPIError {
            throw error
        } catch {
            AppLogger.stashAPI.error("Network error: \(error.localizedDescription, privacy: .public)")
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
        let rating100: Int?
        let o_counter: Int?
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
                    rating100
                    o_counter
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
            // Handle random sort with seed
            if filter.sortField == .random {
                let seed = filter.randomSeed ?? Int.random(in: 10_000_000..<100_000_000)
                filterVariables["sort"] = "random_\(seed)"
            } else {
                filterVariables["sort"] = filter.sortField.rawValue
            }
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

    func findGalleries(query: String? = nil, page: Int = 1, perPage: Int? = nil) async throws -> FindGalleriesResult {
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

        // Determine page size: use larger limit when searching to ensure comprehensive results
        let pageSize = perPage ?? (query != nil && !(query?.isEmpty ?? true) ? 100 : 25)
        var filterVariables: [String: Any] = [
            "page": page,
            "per_page": pageSize,
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

    func findTags(query: String? = nil, page: Int = 1, perPage: Int? = nil) async throws -> FindTagsResult {
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

        // Determine page size: use larger limit when searching to ensure comprehensive results
        let pageSize = perPage ?? (query != nil && !(query?.isEmpty ?? true) ? 100 : 25)
        var filterVariables: [String: Any] = [
            "page": page,
            "per_page": pageSize,
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
        let rating100: Int?
        let o_counter: Int?
        let paths: StashScenePaths
        let files: [StashSceneFile]?
        let tags: [StashSceneTag]?
    }

    struct StashSceneTag: Decodable {
        let id: String
        let name: String
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
        try await findScenes(page: page, perPage: perPage, filter: nil, query: query)
    }

    func findScenes(page: Int, perPage: Int, filter: SceneFilterCriteria?, query: String? = nil) async throws -> FindScenesResult {
        let graphQLQuery = """
        query FindScenes($filter: FindFilterType, $scene_filter: SceneFilterType) {
            findScenes(filter: $filter, scene_filter: $scene_filter) {
                count
                scenes {
                    id
                    title
                    details
                    date
                    rating100
                    o_counter
                    paths {
                        screenshot
                        stream
                    }
                    files {
                        width
                        height
                        duration
                    }
                    tags {
                        id
                        name
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
            // Handle random sort with seed
            if filter.sortField == .random {
                let seed = filter.randomSeed ?? Int.random(in: 10_000_000..<100_000_000)
                filterVariables["sort"] = "random_\(seed)"
            } else {
                filterVariables["sort"] = filter.sortField.rawValue
            }
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

        // Build SceneFilterType if we have filter criteria
        if let filter = filter, filter.hasActiveFilters {
            var sceneFilter: [String: Any] = [:]

            // Gallery filter (scenes use 'galleries' field like images)
            if !filter.galleryIds.isEmpty {
                sceneFilter["galleries"] = [
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
                sceneFilter["o_counter"] = oCountCriterion
            }

            // Rating filter (uses rating100 in API, 1-100 scale)
            if filter.ratingEnabled {
                var ratingCriterion: [String: Any] = [
                    "modifier": filter.ratingModifier.rawValue
                ]
                if filter.ratingModifier.requiresRange {
                    ratingCriterion["value"] = SceneFilterCriteria.ratingToAPI(filter.ratingRange.min ?? 1)
                    ratingCriterion["value2"] = SceneFilterCriteria.ratingToAPI(filter.ratingRange.max ?? 5)
                } else if filter.ratingModifier.requiresValue, let value = filter.ratingValue {
                    ratingCriterion["value"] = SceneFilterCriteria.ratingToAPI(value)
                }
                sceneFilter["rating100"] = ratingCriterion
            }

            // Tags filter
            if !filter.tagIds.isEmpty {
                sceneFilter["tags"] = [
                    "value": filter.tagIds,
                    "modifier": filter.tagModifier.rawValue
                ]
            }

            if !sceneFilter.isEmpty {
                variables["scene_filter"] = sceneFilter
            }
        }

        let response: FindScenesResponse = try await self.query(graphQLQuery, variables: variables)
        return response.findScenes
    }

    // MARK: - Image Mutations

    struct ImageUpdateResponse: Decodable {
        let imageUpdate: ImageUpdateResult
    }

    struct ImageUpdateResult: Decodable {
        let id: String
        let rating100: Int?
    }

    func updateImageRating(imageId: String, rating100: Int?) async throws {
        let mutation = """
        mutation ImageUpdate($input: ImageUpdateInput!) {
            imageUpdate(input: $input) {
                id
                rating100
            }
        }
        """

        var input: [String: Any] = ["id": imageId]
        if let rating100 = rating100 {
            input["rating100"] = rating100
        } else {
            input["rating100"] = NSNull()
        }

        let _: ImageUpdateResponse = try await self.query(mutation, variables: ["input": input])
    }

    struct ImageIncrementOResponse: Decodable {
        let imageIncrementO: Int
    }

    struct ImageDecrementOResponse: Decodable {
        let imageDecrementO: Int
    }

    func incrementImageOCounter(imageId: String) async throws -> Int {
        let mutation = """
        mutation ImageIncrementO($id: ID!) {
            imageIncrementO(id: $id)
        }
        """

        let response: ImageIncrementOResponse = try await self.query(mutation, variables: ["id": imageId])
        return response.imageIncrementO
    }

    func decrementImageOCounter(imageId: String) async throws -> Int {
        let mutation = """
        mutation ImageDecrementO($id: ID!) {
            imageDecrementO(id: $id)
        }
        """

        let response: ImageDecrementOResponse = try await self.query(mutation, variables: ["id": imageId])
        return response.imageDecrementO
    }

    // MARK: - Scene/Video Mutations

    struct SceneUpdateResponse: Decodable {
        let sceneUpdate: SceneUpdateResult
    }

    struct SceneUpdateResult: Decodable {
        let id: String
        let rating100: Int?
    }

    func updateSceneRating(sceneId: String, rating100: Int?) async throws {
        let mutation = """
        mutation SceneUpdate($input: SceneUpdateInput!) {
            sceneUpdate(input: $input) {
                id
                rating100
            }
        }
        """

        var input: [String: Any] = ["id": sceneId]
        if let rating100 = rating100 {
            input["rating100"] = rating100
        } else {
            input["rating100"] = NSNull()
        }

        let _: SceneUpdateResponse = try await self.query(mutation, variables: ["input": input])
    }

    struct SceneIncrementOResponse: Decodable {
        let sceneIncrementO: Int
    }

    struct SceneDecrementOResponse: Decodable {
        let sceneDecrementO: Int
    }

    func incrementSceneOCounter(sceneId: String) async throws -> Int {
        let mutation = """
        mutation SceneIncrementO($id: ID!) {
            sceneIncrementO(id: $id)
        }
        """

        let response: SceneIncrementOResponse = try await self.query(mutation, variables: ["id": sceneId])
        return response.sceneIncrementO
    }

    func decrementSceneOCounter(sceneId: String) async throws -> Int {
        let mutation = """
        mutation SceneDecrementO($id: ID!) {
            sceneDecrementO(id: $id)
        }
        """

        let response: SceneDecrementOResponse = try await self.query(mutation, variables: ["id": sceneId])
        return response.sceneDecrementO
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
