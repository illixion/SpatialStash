import Foundation

public enum NextcloudError: Error, LocalizedError, Equatable {
    case invalidServerURL(String)
    case unauthorized
    case httpStatus(Int, body: String)
    case transport(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL(let value):
            return "Not a valid server URL: \(value)"
        case .unauthorized:
            return "The server rejected these credentials."
        case .httpStatus(let code, let body):
            return "Server returned HTTP \(code)\(body.isEmpty ? "" : ": \(body)")"
        case .transport(let message):
            return "Network error: \(message)"
        case .malformedResponse(let message):
            return "Could not read the server's response: \(message)"
        }
    }
}

/// Talks to a Nextcloud instance's media APIs.
///
/// An actor because the server config is mutable (the user can repoint it in
/// settings while a gallery is mid-page) and every request reads it.
public actor NextcloudClient {
    private var server: NextcloudServer
    private let session: URLSession

    public init(server: NextcloudServer, session: URLSession = .shared) {
        self.server = server
        self.session = session
    }

    public func updateServer(_ server: NextcloudServer) {
        self.server = server
    }

    public var currentServer: NextcloudServer { server }

    // MARK: - Search

    /// Fetches one page of media.
    public func search(_ query: NextcloudQuery) async throws -> NextcloudPage {
        let body = NextcloudSearchRequest.body(for: query, scope: server.searchScope)
        let url = server.baseURL.appendingPathComponent("remote.php/dav/")

        var request = URLRequest(url: url)
        request.httpMethod = "SEARCH"
        request.httpBody = Data(body.utf8)
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(server.authorizationHeader, forHTTPHeaderField: "Authorization")

        let data = try await perform(request)
        let entries = try NextcloudMultiStatusParser.parse(data)
        let items = NextcloudItemMapper.items(from: entries, server: server)

        // Compare against the *entry* count, not the mapped count: entries the
        // mapper dropped (a collection, a file with no content type) still
        // consumed a slot in the server's page, so a full page that maps to
        // fewer items is not the end of the library.
        return NextcloudPage(items: items, hasMore: entries.count >= query.limit)
    }

    /// Cheap reachability + credential check, for a "Test Connection" button.
    /// Returns the number of items the configured root currently exposes.
    public func verify(kind: NextcloudQuery.Kind = .both) async throws -> Int {
        // Asking for a single result is enough to prove auth, scope and parsing
        // all work, without pulling a page the caller throws away.
        let probe = NextcloudQuery(kind: kind, offset: 0, limit: 1)
        let page = try await search(probe)
        return page.items.count
    }

    // MARK: - Downloads

    /// Preview URL plus the auth header a loader needs to fetch it. The URL
    /// alone is not usable — the preview endpoint requires authentication, so
    /// handing a bare URL to an image view yields a 401.
    public func previewRequest(fileID: Int, size: Int) -> URLRequest? {
        guard let url = server.previewURL(fileID: fileID, size: size) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(server.authorizationHeader, forHTTPHeaderField: "Authorization")
        return request
    }

    /// Authenticated request for the original file.
    public func downloadRequest(for item: NextcloudItem) -> URLRequest {
        var request = URLRequest(url: item.downloadURL)
        request.setValue(server.authorizationHeader, forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Transport

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NextcloudError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NextcloudError.malformedResponse("not an HTTP response")
        }

        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw NextcloudError.unauthorized
        default:
            let body = String(data: data.prefix(512), encoding: .utf8) ?? ""
            throw NextcloudError.httpStatus(http.statusCode, body: body)
        }
    }
}
