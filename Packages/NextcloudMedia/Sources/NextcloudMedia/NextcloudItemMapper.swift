import Foundation

/// Turns parsed multi-status entries into `NextcloudItem`s.
///
/// Separate from the parser so the "what does this property mean" decisions are
/// testable against hand-written entries, with no XML involved.
enum NextcloudItemMapper {

    /// DAV dates are RFC 1123 in GMT. A fixed `en_US_POSIX` locale is required:
    /// the month and weekday names are English regardless of the device, so a
    /// device-locale formatter silently fails to parse on a non-English system.
    static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    static func items(from entries: [NextcloudMultiStatusParser.Entry],
                      server: NextcloudServer) -> [NextcloudItem] {
        entries.compactMap { item(from: $0, server: server) }
    }

    static func item(from entry: NextcloudMultiStatusParser.Entry,
                     server: NextcloudServer) -> NextcloudItem? {
        guard !entry.isCollection else { return nil }

        let props = entry.properties
        guard let fileIDText = props[NextcloudMultiStatusParser.Prop.fileID],
              let fileID = Int(fileIDText) else { return nil }

        // A directory entry has no content type; so does a file the server
        // could not classify. Neither is displayable media.
        guard let contentType = props[NextcloudMultiStatusParser.Prop.contentType],
              !contentType.isEmpty else { return nil }

        guard let relativePath = relativePath(fromHref: entry.href, username: server.username),
              let downloadURL = downloadURL(forHref: entry.href, server: server)
        else { return nil }

        let length = props[NextcloudMultiStatusParser.Prop.contentLength]
            .flatMap(Int64.init) ?? 0

        // DAV wraps ETags in quotes, and a weak validator prefixes `W/`.
        // Neither belongs in a cache key.
        var etag = props[NextcloudMultiStatusParser.Prop.etag] ?? ""
        if etag.hasPrefix("W/") { etag.removeFirst(2) }
        etag = etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        let modified = props[NextcloudMultiStatusParser.Prop.lastModified]
            .flatMap { rfc1123.date(from: $0) }

        // Nextcloud spells this "true"/"false"; treat anything else as absent
        // rather than as false, so a future spelling change fails toward
        // "ask the server" instead of "never show a thumbnail".
        let hasPreview = props[NextcloudMultiStatusParser.Prop.hasPreview]
            .map { $0.lowercased() == "true" } ?? false

        let pixelSize = props[NextcloudMultiStatusParser.Prop.photosSize]
            .flatMap(parsePixelSize)

        // The photos metadata timestamp is a Unix epoch integer, unlike every
        // other date in this response.
        let captureDate = props[NextcloudMultiStatusParser.Prop.originalDate]
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))

        let blurHash = props[NextcloudMultiStatusParser.Prop.blurHash]
            .flatMap { $0.isEmpty ? nil : $0 }

        return NextcloudItem(
            fileID: fileID,
            path: relativePath,
            downloadURL: downloadURL,
            contentType: contentType,
            contentLength: length,
            etag: etag,
            lastModified: modified,
            hasPreview: hasPreview,
            pixelSize: pixelSize,
            captureDate: captureDate,
            blurHash: blurHash)
    }

    /// `"4032x3024"` → 4032×3024. Returns nil for the empty string, which is
    /// what an absent-but-listed property looks like.
    static func parsePixelSize(_ raw: String) -> NextcloudItem.PixelSize? {
        let parts = raw.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              width > 0, height > 0 else { return nil }
        return NextcloudItem.PixelSize(width: width, height: height)
    }

    /// Strips `/remote.php/dav/files/<user>/` off a response href and decodes it.
    ///
    /// The prefix is matched rather than assumed at a fixed offset because the
    /// instance may live under a subdirectory (`https://host/nextcloud/…`), in
    /// which case the href carries that prefix too.
    static func relativePath(fromHref href: String, username: String) -> String? {
        let marker = "/remote.php/dav/files/\(username)/"
        guard let range = href.range(of: marker) else { return nil }
        let encoded = String(href[range.upperBound...])
        guard !encoded.isEmpty else { return nil }
        return encoded.removingPercentEncoding ?? encoded
    }

    /// The href is server-relative and already percent-encoded, so it is
    /// appended to the origin as a *path string* rather than via
    /// `appendingPathComponent`, which would double-encode it.
    static func downloadURL(forHref href: String, server: NextcloudServer) -> URL? {
        guard var components = URLComponents(url: server.baseURL,
                                             resolvingAgainstBaseURL: false)
        else { return nil }
        // Preserve any subdirectory the instance is mounted under: the href is
        // absolute from the host root and already includes it.
        components.percentEncodedPath = href
        components.query = nil
        return components.url
    }
}
