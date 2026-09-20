import Foundation

/// A collection in the user's files, for choosing a library root.
///
/// Browsing beats typing a path: the root decides what the whole library
/// contains, a typo yields an empty gallery rather than an error, and the
/// interesting folder is rarely at the top level.
public struct NextcloudFolder: Sendable, Equatable, Identifiable {
    /// Path relative to the user's files root, without leading or trailing
    /// slashes. `""` is the account root.
    public let path: String
    public let name: String
    /// Direct children, when the server reported a count. Nextcloud does not
    /// report one for every collection, so this is advisory.
    public let childCount: Int?

    public var id: String { path }

    /// What `NextcloudServer.root` should be set to for this folder.
    public var asRoot: String { path }

    public init(path: String, name: String, childCount: Int?) {
        self.path = path
        self.name = name
        self.childCount = childCount
    }
}

extension NextcloudClient {

    /// Lists the collections directly inside `path`.
    ///
    /// A `PROPFIND` with `Depth: 1`, which is the right tool here and the wrong
    /// one for listing media: it returns one level of one folder, which is
    /// exactly a dropdown's worth, whereas paging a library through it would
    /// cost a request per folder.
    ///
    /// - Parameter path: relative to the user's files root; `""` is the root.
    public func folders(in path: String = "") async throws -> [NextcloudFolder] {
        let normalized = NextcloudServer.normalizeRoot(path)
        let body = """
            <?xml version="1.0" encoding="UTF-8"?>
            <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" \
            xmlns:nc="http://nextcloud.org/ns">
              <d:prop>
                <d:resourcetype/>
                <d:displayname/>
                <oc:fileid/>
                <oc:size/>
              </d:prop>
            </d:propfind>
            """

        var url = currentServer.baseURL
            .appendingPathComponent("remote.php/dav/files")
            .appendingPathComponent(currentServer.username)
        for component in normalized.split(separator: "/") {
            url.appendPathComponent(String(component))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.httpBody = Data(body.utf8)
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Depth 1 is this collection plus its immediate children. Depth
        // "infinity" is refused by most Nextcloud deployments outright.
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue(currentServer.authorizationHeader, forHTTPHeaderField: "Authorization")

        let data = try await performRequest(request)
        let entries = try NextcloudMultiStatusParser.parse(data)

        return entries.compactMap { entry -> NextcloudFolder? in
            guard entry.isCollection else { return nil }
            guard let relative = NextcloudItemMapper.relativePath(
                fromHref: entry.href, username: currentServer.username) else { return nil }

            // PROPFIND always echoes the collection being listed as its own
            // first result. Including it would put "Photos" inside "Photos".
            let trimmed = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard trimmed != normalized else { return nil }

            let name = (trimmed as NSString).lastPathComponent
            let count = entry.properties["http://owncloud.org/ns|size"].flatMap(Int.init)
            return NextcloudFolder(path: trimmed, name: name, childCount: count)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
