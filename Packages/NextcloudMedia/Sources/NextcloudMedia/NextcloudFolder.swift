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
    /// Recursive size of the collection in **bytes**, as `oc:size` reports it.
    ///
    /// Not a count of anything — an earlier version of this called it
    /// `childCount`, which read plausibly right up until a live listing
    /// returned 343,669,554,388 for a music folder. Useful for telling a real
    /// media folder apart from an empty one when choosing a library root,
    /// which is the only thing it is used for.
    public let totalBytes: Int64?

    public var id: String { path }

    /// What `NextcloudServer.root` should be set to for this folder.
    public var asRoot: String { path }

    public init(path: String, name: String, totalBytes: Int64?) {
        self.path = path
        self.name = name
        self.totalBytes = totalBytes
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
        return NextcloudFolder.folders(from: entries,
                                       username: currentServer.username,
                                       listing: normalized)
    }
}

extension NextcloudFolder {
    /// The collections a `PROPFIND Depth: 1` response lists, excluding the one
    /// being listed.
    ///
    /// Split out of `folders(in:)` so it can be tested without a server — the
    /// mapping is where the mistakes live, as `oc:size` being bytes rather than
    /// a child count demonstrated.
    static func folders(from entries: [NextcloudMultiStatusParser.Entry],
                        username: String,
                        listing normalizedPath: String) -> [NextcloudFolder] {
        entries.compactMap { entry -> NextcloudFolder? in
            guard entry.isCollection else { return nil }
            guard let relative = NextcloudItemMapper.relativePath(
                fromHref: entry.href, username: username) else { return nil }

            // PROPFIND always echoes the collection being listed as its own
            // first result. Including it would put "Photos" inside "Photos".
            let trimmed = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard trimmed != normalizedPath else { return nil }

            let name = (trimmed as NSString).lastPathComponent
            let bytes = entry.properties["http://owncloud.org/ns|size"].flatMap(Int64.init)
            return NextcloudFolder(path: trimmed, name: name, totalBytes: bytes)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
