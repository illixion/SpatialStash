import Foundation

/// Parses a WebDAV `207 Multi-Status` body into `NextcloudItem`s.
///
/// Uses `XMLParser` rather than a regex or a dependency. The shape that forces
/// real parsing is `<d:propstat>`: a response carries **one propstat block per
/// status**, so a file whose photo metadata was never extracted comes back as a
/// 200 block with the ordinary properties *and* a 404 block naming
/// `nc:metadata-photos-size` and friends. Scraping tag values without tracking
/// which block they came from reads those 404 placeholders as present-but-empty.
struct NextcloudMultiStatusParser {

    /// Collections come back alongside files and are dropped: a search scoped to
    /// a mimetype never matches one, but a PROPFIND on the same parser would.
    struct Entry {
        var href: String = ""
        var isCollection = false
        var properties: [String: String] = [:]
    }

    enum ParseError: Error, LocalizedError {
        case malformedXML(underlying: Error?)

        var errorDescription: String? {
            switch self {
            case .malformedXML(let underlying):
                return "Malformed WebDAV response: \(underlying?.localizedDescription ?? "unknown")"
            }
        }
    }

    static func parse(_ data: Data) throws -> [Entry] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw ParseError.malformedXML(underlying: parser.parserError)
        }
        return delegate.entries
    }

    /// Namespace-aware: `shouldProcessNamespaces` hands us the local name plus
    /// the URI, so this does not care whether a server spells the DAV prefix
    /// `d:` or `D:` — both occur in the wild and a prefix-matching parser
    /// silently returns nothing against the other one.
    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []

        private var current: Entry?
        private var currentPropertyKey: String?
        private var text = ""
        /// nil until a `<propstat>` reports its `<status>`; properties are held
        /// aside until then because the status arrives *after* them.
        private var pendingProperties: [String: String] = [:]
        private var inPropstat = false
        private var inResponseHref = false

        private static let davNS = "DAV:"

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            text = ""
            let ns = namespaceURI ?? ""

            switch (ns, elementName) {
            case (Self.davNS, "response"):
                current = Entry()
                inResponseHref = false
            case (Self.davNS, "href"):
                // Only the response's own href identifies the file; a scope
                // href inside a search request echo would otherwise overwrite it.
                if current != nil, !inPropstat, current?.href.isEmpty == true {
                    inResponseHref = true
                }
            case (Self.davNS, "propstat"):
                inPropstat = true
                pendingProperties = [:]
            case (Self.davNS, "collection"):
                current?.isCollection = true
            case (Self.davNS, "prop"), (Self.davNS, "status"),
                 (Self.davNS, "multistatus"), (Self.davNS, "resourcetype"):
                break
            default:
                if inPropstat {
                    currentPropertyKey = Self.key(ns: ns, name: elementName)
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let ns = namespaceURI ?? ""
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""

            switch (ns, elementName) {
            case (Self.davNS, "href"):
                if inResponseHref {
                    current?.href = value
                    inResponseHref = false
                }
            case (Self.davNS, "status"):
                // This is the whole point of the class: only a 2xx propstat's
                // properties are real. Anything else is the server listing the
                // properties it could *not* supply.
                if inPropstat, Self.isSuccess(value) {
                    current?.properties.merge(pendingProperties) { _, new in new }
                }
                pendingProperties = [:]
            case (Self.davNS, "propstat"):
                inPropstat = false
                pendingProperties = [:]
            case (Self.davNS, "response"):
                if let entry = current, !entry.href.isEmpty {
                    entries.append(entry)
                }
                current = nil
            default:
                if inPropstat, let key = currentPropertyKey,
                   key == Self.key(ns: ns, name: elementName) {
                    pendingProperties[key] = value
                    currentPropertyKey = nil
                }
            }
        }

        /// `HTTP/1.1 200 OK` → true. Parsed rather than compared against a
        /// literal because servers vary the reason phrase and the HTTP version.
        static func isSuccess(_ status: String) -> Bool {
            let parts = status.split(separator: " ")
            guard parts.count >= 2, let code = Int(parts[1]) else { return false }
            return (200..<300).contains(code)
        }

        static func key(ns: String, name: String) -> String {
            "\(ns)|\(name)"
        }
    }
}

// MARK: - Property keys

extension NextcloudMultiStatusParser {
    enum Prop {
        static let dav = "DAV:"
        static let oc = "http://owncloud.org/ns"
        static let nc = "http://nextcloud.org/ns"

        static let contentType = "\(dav)|getcontenttype"
        static let lastModified = "\(dav)|getlastmodified"
        static let contentLength = "\(dav)|getcontentlength"
        static let etag = "\(dav)|getetag"
        static let fileID = "\(oc)|fileid"
        static let hasPreview = "\(nc)|has-preview"
        static let photosSize = "\(nc)|metadata-photos-size"
        static let originalDate = "\(nc)|metadata-photos-original_date_time"
        static let blurHash = "\(nc)|metadata-blurhash"
    }
}
