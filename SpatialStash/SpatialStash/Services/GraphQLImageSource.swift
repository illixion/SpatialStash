/*
 Spatial Stash - GraphQL Image Source

 ImageSource implementation that fetches images from Stash server via GraphQL.
 */

import Foundation

/// Image source that fetches from Stash GraphQL API
final class GraphQLImageSource: ImageSource, @unchecked Sendable {
    private let apiClient: StashAPIClient

    init(apiClient: StashAPIClient) {
        self.apiClient = apiClient
    }

    func fetchImages(page: Int, pageSize: Int) async throws -> ImageFetchResult {
        try await fetchImages(page: page, pageSize: pageSize, filter: nil)
    }

    func fetchImages(page: Int, pageSize: Int, filter: ImageFilterCriteria?) async throws -> ImageFetchResult {
        // Stash uses 1-indexed pages
        let stashPage = page + 1
        print("[GraphQLImageSource] Fetching images page \(stashPage), pageSize \(pageSize), hasFilter: \(filter != nil)")

        let result = try await apiClient.findImages(page: stashPage, perPage: pageSize, filter: filter)
        print("[GraphQLImageSource] Got \(result.images.count) images, total: \(result.count)")

        let images = result.images.compactMap { stashImage -> GalleryImage? in
            guard let imageURLString = stashImage.paths.image,
                  let imageURL = URL(string: imageURLString) else {
                return nil
            }

            let thumbnailURL: URL
            if let thumbString = stashImage.paths.thumbnail,
               let thumbURL = URL(string: thumbString) {
                thumbnailURL = thumbURL
            } else {
                thumbnailURL = imageURL
            }

            return GalleryImage(
                thumbnailURL: thumbnailURL,
                fullSizeURL: imageURL,
                title: stashImage.title
            )
        }

        let totalPages = (result.count + pageSize - 1) / pageSize
        let hasMore = (page + 1) < totalPages

        return ImageFetchResult(
            images: images,
            hasMore: hasMore,
            totalCount: result.count
        )
    }
}
