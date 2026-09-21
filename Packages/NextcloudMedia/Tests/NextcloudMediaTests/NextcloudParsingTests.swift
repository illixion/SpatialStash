import Foundation
import Testing
@testable import NextcloudMedia

private let server = NextcloudServer(
    baseURL: URL(string: "https://cloud.example.com")!,
    username: "illixion",
    appPassword: "app-password",
    root: "Photos")

// MARK: - Multi-status parsing

@Suite("Multi-status parsing")
struct MultiStatusParsingTests {

    /// The shape that motivates the parser: one 200 propstat and one 404
    /// propstat in the same response. This is what every bulk-scanned file
    /// looks like, because the photos metadata job never ran for them.
    static let mixedStatusResponse = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" \
        xmlns:nc="http://nextcloud.org/ns">
          <d:response>
            <d:href>/remote.php/dav/files/illixion/Photos/2026/03/IMG_7440.HEIC</d:href>
            <d:propstat>
              <d:prop>
                <d:getcontenttype>image/heic</d:getcontenttype>
                <d:getlastmodified>Thu, 12 Feb 2026 11:16:21 GMT</d:getlastmodified>
                <d:getcontentlength>2314883</d:getcontentlength>
                <d:getetag>&quot;1461995ec81849c2e753ce706416a5ff&quot;</d:getetag>
                <oc:fileid>34349</oc:fileid>
                <nc:has-preview>true</nc:has-preview>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
            <d:propstat>
              <d:prop>
                <nc:metadata-photos-size/>
                <nc:metadata-photos-original_date_time/>
              </d:prop>
              <d:status>HTTP/1.1 404 Not Found</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

    @Test("Properties from a 404 propstat are not treated as present")
    func ignoresNotFoundPropstat() throws {
        let entries = try NextcloudMultiStatusParser.parse(Data(Self.mixedStatusResponse.utf8))
        #expect(entries.count == 1)

        let item = try #require(NextcloudItemMapper.item(from: entries[0], server: server))
        #expect(item.fileID == 34349)
        #expect(item.contentType == "image/heic")
        #expect(item.hasPreview)
        // The whole point: these were listed, but under a 404.
        #expect(item.pixelSize == nil)
        #expect(item.captureDate == nil)
    }

    @Test("ETag loses its quotes and weak-validator prefix")
    func normalizesETag() throws {
        let entries = try NextcloudMultiStatusParser.parse(Data(Self.mixedStatusResponse.utf8))
        let item = try #require(NextcloudItemMapper.item(from: entries[0], server: server))
        #expect(item.etag == "1461995ec81849c2e753ce706416a5ff")
    }

    @Test("Uppercase DAV prefix parses identically")
    func handlesUppercasePrefix() throws {
        // Some servers emit `D:`; a prefix-matching parser returns nothing here.
        let xml = Self.mixedStatusResponse
            .replacingOccurrences(of: "<d:", with: "<D:")
            .replacingOccurrences(of: "</d:", with: "</D:")
            .replacingOccurrences(of: "xmlns:d=", with: "xmlns:D=")
        let entries = try NextcloudMultiStatusParser.parse(Data(xml.utf8))
        #expect(entries.count == 1)
        #expect(NextcloudItemMapper.item(from: entries[0], server: server)?.fileID == 34349)
    }

    @Test("Collections are dropped")
    func dropsCollections() throws {
        let xml = """
            <?xml version="1.0"?>
            <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
              <d:response>
                <d:href>/remote.php/dav/files/illixion/Photos/2026/</d:href>
                <d:propstat>
                  <d:prop>
                    <d:resourcetype><d:collection/></d:resourcetype>
                    <oc:fileid>100</oc:fileid>
                  </d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
            </d:multistatus>
            """
        let entries = try NextcloudMultiStatusParser.parse(Data(xml.utf8))
        #expect(entries.count == 1)
        #expect(NextcloudItemMapper.item(from: entries[0], server: server) == nil)
    }

    @Test("Malformed XML throws rather than returning an empty page")
    func throwsOnMalformedXML() {
        // Returning [] here would read as "the library is empty" and wipe a grid.
        #expect(throws: (any Error).self) {
            try NextcloudMultiStatusParser.parse(Data("<d:multistatus><oops".utf8))
        }
    }

    @Test("Percent-encoded paths with spaces and ampersands decode")
    func decodesPaths() throws {
        let xml = """
            <?xml version="1.0"?>
            <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
              <d:response>
                <d:href>/remote.php/dav/files/illixion/Photos/Rock%20%26%20Roll/a%20b.jpg</d:href>
                <d:propstat>
                  <d:prop>
                    <d:getcontenttype>image/jpeg</d:getcontenttype>
                    <oc:fileid>7</oc:fileid>
                  </d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
            </d:multistatus>
            """
        let entries = try NextcloudMultiStatusParser.parse(Data(xml.utf8))
        let item = try #require(NextcloudItemMapper.item(from: entries[0], server: server))
        #expect(item.path == "Photos/Rock & Roll/a b.jpg")
        #expect(item.filename == "a b.jpg")
        // The download URL keeps the encoding rather than double-encoding it.
        #expect(item.downloadURL.absoluteString
            == "https://cloud.example.com/remote.php/dav/files/illixion/Photos/Rock%20%26%20Roll/a%20b.jpg")
    }
}

// MARK: - Mapping details

@Suite("Item mapping")
struct ItemMappingTests {

    @Test("Pixel size parses, and an empty value stays nil")
    func parsesPixelSize() {
        #expect(NextcloudItemMapper.parsePixelSize("4032x3024")
            == NextcloudItem.PixelSize(width: 4032, height: 3024))
        #expect(NextcloudItemMapper.parsePixelSize("") == nil)
        #expect(NextcloudItemMapper.parsePixelSize("0x100") == nil)
        #expect(NextcloudItemMapper.parsePixelSize("garbage") == nil)
    }

    @Test("RFC 1123 dates parse regardless of device locale")
    func parsesDatesUnderForeignLocale() {
        // en_US_POSIX is pinned precisely so this holds; without it the English
        // month name fails to parse under a non-English locale.
        let date = NextcloudItemMapper.rfc1123.date(from: "Thu, 12 Feb 2026 11:16:21 GMT")
        #expect(date == Date(timeIntervalSince1970: 1_770_894_981))
    }

    @Test("Subdirectory installs keep their path prefix")
    func handlesSubdirectoryInstall() {
        let subdir = NextcloudServer(
            baseURL: URL(string: "https://host.example/nextcloud")!,
            username: "illixion", appPassword: "x", root: "Photos")
        let href = "/nextcloud/remote.php/dav/files/illixion/Photos/a.jpg"
        #expect(NextcloudItemMapper.relativePath(fromHref: href, username: "illixion")
            == "Photos/a.jpg")
        #expect(NextcloudItemMapper.downloadURL(forHref: href, server: subdir)?.absoluteString
            == "https://host.example/nextcloud/remote.php/dav/files/illixion/Photos/a.jpg")
    }
}

// MARK: - Request building

@Suite("Search request")
struct SearchRequestTests {

    @Test("Scope is server-relative and honours the root")
    func buildsScope() {
        #expect(server.searchScope == "/files/illixion/Photos")
        let whole = NextcloudServer(baseURL: server.baseURL, username: "illixion",
                                    appPassword: "x", root: "")
        #expect(whole.searchScope == "/files/illixion")
    }

    @Test("Root normalization tolerates stray slashes")
    func normalizesRoot() {
        #expect(NextcloudServer.normalizeRoot("/Photos/") == "Photos")
        #expect(NextcloudServer.normalizeRoot("  Photos  ") == "Photos")
        #expect(NextcloudServer.normalizeRoot("/") == "")
    }

    @Test("A single mimetype is not wrapped in <d:or>")
    func singleMimeHasNoOr() {
        let body = NextcloudSearchRequest.body(
            for: NextcloudQuery(kind: .images), scope: server.searchScope)
        #expect(body.contains("image/%"))
        #expect(!body.contains("<d:or>"))
    }

    @Test("Both kinds produce an <d:or> of two patterns")
    func bothKindsUseOr() {
        let body = NextcloudSearchRequest.body(
            for: NextcloudQuery(kind: .both), scope: server.searchScope)
        #expect(body.contains("<d:or>"))
        #expect(body.contains("image/%"))
        #expect(body.contains("video/%"))
    }

    @Test("Ampersands in a search term are XML-escaped")
    func escapesSearchTerm() {
        // A raw & makes the server reject the whole body as malformed XML,
        // surfacing as a 400 with no clue which term caused it.
        let body = NextcloudSearchRequest.body(
            for: NextcloudQuery(searchTerm: "Rock & Roll"), scope: server.searchScope)
        #expect(body.contains("Rock &amp; Roll"))
        #expect(!body.contains("Rock & Roll"))
    }

    @Test("LIKE wildcards in a search term are escaped")
    func escapesLikeWildcards() {
        let body = NextcloudSearchRequest.body(
            for: NextcloudQuery(searchTerm: "100%"), scope: server.searchScope)
        // The literal % is escaped; the surrounding wildcards are not.
        #expect(body.contains("%100\\%%"))
    }

    @Test("Paging uses nresults and firstresult")
    func buildsPaging() {
        let body = NextcloudSearchRequest.body(
            for: NextcloudQuery(offset: 300, limit: 100), scope: server.searchScope)
        #expect(body.contains("<d:nresults>100</d:nresults>"))
        #expect(body.contains("<nc:firstresult>300</nc:firstresult>"))
    }

    @Test("Sort direction and field are honoured")
    func buildsSort() {
        let ascending = NextcloudSearchRequest.body(
            for: NextcloudQuery(sortField: .path, descending: false),
            scope: server.searchScope)
        #expect(ascending.contains("<d:displayname/>"))
        #expect(ascending.contains("<d:ascending/>"))
        #expect(!ascending.contains("<d:descending/>"))
    }
}

// MARK: - URLs and credentials

@Suite("Server URLs")
struct ServerURLTests {

    @Test("Preview URL keeps aspect and refuses the generic icon")
    func buildsPreviewURL() throws {
        let url = try #require(server.previewURL(fileID: 34349, size: 512))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let pairs = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        #expect(pairs["fileId"] == "34349")
        #expect(pairs["x"] == "512")
        #expect(pairs["a"] == "1")
        // A generic filetype icon returned as a 200 would get cached forever.
        #expect(pairs["forceIcon"] == "0")
    }

    @Test("Basic auth header encodes user and app password")
    func buildsAuthHeader() {
        let expected = "Basic " + Data("illixion:app-password".utf8).base64EncodedString()
        #expect(server.authorizationHeader == expected)
    }

    @Test("Typed server URLs normalize to an origin")
    func normalizesServerURL() {
        let cases: [(String, String?)] = [
            ("cloud.example.com", "https://cloud.example.com"),
            ("https://cloud.example.com/", "https://cloud.example.com"),
            ("https://cloud.example.com/index.php/apps/files", "https://cloud.example.com"),
            ("https://host.example/nextcloud/index.php/apps/files", "https://host.example/nextcloud"),
            ("https://cloud.example.com/login/v2/flow/abc", "https://cloud.example.com"),
            ("   ", nil),
        ]
        for (input, expected) in cases {
            let result = NextcloudLoginFlow.normalizeServerURL(input)?.absoluteString
            #expect(result == expected, "input: \(input)")
        }
    }
}

// MARK: - Folder listing

@Suite("Folder listing")
struct FolderListingTests {

    /// Shaped after a real `PROPFIND Depth: 1` on the account root: the listed
    /// collection echoed first, then its children, then a file that has to be
    /// ignored because the dropdown is offering folders to descend into.
    private let accountRoot = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response>
            <d:href>/remote.php/dav/files/illixion/</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype><d:collection/></d:resourcetype>
                <oc:size>518000000000</oc:size>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/illixion/Photos/</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype><d:collection/></d:resourcetype>
                <oc:size>174308560190</oc:size>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/illixion/Music/</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype><d:collection/></d:resourcetype>
                <oc:size>343669554388</oc:size>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/illixion/Shared/</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype><d:collection/></d:resourcetype>
                <oc:size>0</oc:size>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/illixion/readme.txt</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype/>
                <oc:size>12</oc:size>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

    @Test("The listed collection is dropped, its children kept and sorted")
    func listsChildrenOnly() throws {
        let entries = try NextcloudMultiStatusParser.parse(Data(accountRoot.utf8))
        let folders = NextcloudFolder.folders(from: entries, username: "illixion", listing: "")

        // Not four: the echoed root is excluded, or choosing a root would offer
        // the very folder being listed as something to descend into.
        #expect(folders.map(\.path) == ["Music", "Photos", "Shared"])
    }

    @Test("oc:size is bytes, not a count of children")
    func readsSizeAsBytes() throws {
        // The bug this exists for: the field was called childCount and read
        // plausibly until a live listing reported 343,669,554,388 children.
        let entries = try NextcloudMultiStatusParser.parse(Data(accountRoot.utf8))
        let folders = NextcloudFolder.folders(from: entries, username: "illixion", listing: "")
        #expect(folders.first { $0.name == "Music" }?.totalBytes == 343_669_554_388)
        #expect(folders.first { $0.name == "Shared" }?.totalBytes == 0)
    }

    @Test("Listing a nested folder drops that folder, not its children")
    func dropsOnlyTheListedCollection() throws {
        let xml = """
            <?xml version="1.0"?>
            <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
              <d:response>
                <d:href>/remote.php/dav/files/illixion/Photos/</d:href>
                <d:propstat>
                  <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
              <d:response>
                <d:href>/remote.php/dav/files/illixion/Photos/2026/</d:href>
                <d:propstat>
                  <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
            </d:multistatus>
            """
        let entries = try NextcloudMultiStatusParser.parse(Data(xml.utf8))
        let folders = NextcloudFolder.folders(from: entries, username: "illixion", listing: "Photos")
        // The child keeps its full relative path — that is what becomes the root.
        #expect(folders.map(\.path) == ["Photos/2026"])
        #expect(folders.map(\.name) == ["2026"])
    }

    @Test("A folder with no reported size still lists")
    func toleratesMissingSize() throws {
        let xml = """
            <?xml version="1.0"?>
            <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
              <d:response>
                <d:href>/remote.php/dav/files/illixion/Templates/</d:href>
                <d:propstat>
                  <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
                  <d:status>HTTP/1.1 200 OK</d:status>
                </d:propstat>
              </d:response>
            </d:multistatus>
            """
        let entries = try NextcloudMultiStatusParser.parse(Data(xml.utf8))
        let folders = NextcloudFolder.folders(from: entries, username: "illixion", listing: "")
        #expect(folders.count == 1)
        #expect(folders[0].totalBytes == nil)
    }
}
