/*
 Spatial Stash - GraphQL Image Source

 ImageSource implementation that fetches images from Stash server via GraphQL.
 */

import Foundation
import os

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
        AppLogger.graphQLImage.debug("Fetching images page \(stashPage, privacy: .public), pageSize \(pageSize, privacy: .public), hasFilter: \(filter != nil, privacy: .public)")

        let result = try await apiClient.findImages(page: stashPage, perPage: pageSize, filter: filter)
        AppLogger.graphQLImage.debug("Got \(result.images.count, privacy: .public) images, total: \(result.count, privacy: .public)")

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
                stashId: stashImage.id,
                thumbnailURL: thumbnailURL,
                fullSizeURL: imageURL,
                title: stashImage.title,
                rating100: stashImage.rating100,
                oCounter: stashImage.o_counter
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
