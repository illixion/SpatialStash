import Foundation

/// Where a Nextcloud library lives and how to reach it.
///
/// `root` is not decoration. An unscoped media search returns everything the
/// account can see, which on a server that also hosts a music library means
/// thousands of album-art JPEGs interleaved with the photos (measured: 3,213 of
/// them against 11,586 real pictures). Every query is scoped to this path.
public struct NextcloudServer: Sendable, Equatable {
    /// Base URL of the instance, e.g. `https://cloud.example.com`.
    public var baseURL: URL
    /// The Nextcloud login name. Part of every DAV path, so it is not optional.
    public var username: String
    /// An **app password** from Login Flow v2, never the account password.
    public var appPassword: String
    /// Library root relative to the user's files, without leading or trailing
    /// slashes — `"Photos"`, or `""` for the whole account.
    public var root: String

    public init(baseURL: URL, username: String, appPassword: String, root: String = "Photos") {
        self.baseURL = baseURL
        self.username = username
        self.appPassword = appPassword
        self.root = NextcloudServer.normalizeRoot(root)
    }

    /// Trims the slashes callers inevitably include, so `"/Photos/"`,
    /// `"Photos"` and `"//Photos"` all address the same collection. Without
    /// this the scope href picks up an empty path segment and the server
    /// answers with an empty result set rather than an error, which reads as
    /// "the library is empty" instead of "the path is malformed".
    public static func normalizeRoot(_ root: String) -> String {
        root.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n"))
    }

    /// The DAV *scope* for a search: a server-relative path with no
    /// `/remote.php/dav` prefix, which is what `<d:href>` inside
    /// `<d:searchrequest>` expects — unlike every other href in the protocol,
    /// which is fully qualified. Mixing the two up yields an empty result set
    /// rather than an error.
    public var searchScope: String {
        root.isEmpty ? "/files/\(username)" : "/files/\(username)/\(root)"
    }

    /// The collection URL for ordinary DAV requests (PROPFIND, GET).
    public var filesBaseURL: URL {
        var url = baseURL.appendingPathComponent("remote.php/dav/files")
        url.appendPathComponent(username)
        for component in root.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    /// `Authorization` header value. App passwords go over Basic, which is what
    /// Nextcloud's own clients do; the transport is HTTPS.
    public var authorizationHeader: String {
        let raw = "\(username):\(appPassword)"
        let encoded = Data(raw.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    /// Server-generated thumbnail for a file. Preferred over downloading the
    /// original for any grid: the server has these pre-rendered when the
    /// `previewgenerator` app is installed.
    ///
    /// - Parameter size: the longest edge in points. The server clamps this to
    ///   its own `preview_max_x/y`, so asking for more than it will make is
    ///   harmless but pointless.
    public func previewURL(fileID: Int, size: Int) -> URL? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("index.php/core/preview"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "fileId", value: String(fileID)),
            URLQueryItem(name: "x", value: String(size)),
            URLQueryItem(name: "y", value: String(size)),
            // a=1 preserves aspect ratio. Without it the server centre-crops to
            // a square, which is wrong for anything but a uniform grid.
            URLQueryItem(name: "a", value: "1"),
            // Refuse the generic filetype icon: a placeholder that arrives as a
            // successful 200 is worse than a failure, because the caller caches
            // it and never retries once a real preview exists.
            URLQueryItem(name: "forceIcon", value: "0"),
        ]
        return components?.url
    }
}
