import Foundation

/// Builds the RFC 5323 `SEARCH` body Nextcloud answers media queries with.
///
/// This is the reason the client does not walk the tree with PROPFIND. A
/// `basicsearch` is resolved as a SQL query against `oc_filecache`, so it
/// returns a flat, sorted, mimetype-filtered page from anywhere in the library
/// at a cost that does not grow with depth or offset. Measured against a
/// 14,799-image instance: 100 results in 82–123 ms, and **79 ms at offset
/// 10,000**. The same library walked with `PROPFIND Depth:1` costs 283 ms just
/// to list 47 folders.
///
/// Kept as a pure string builder, separate from the transport, so the request
/// shape is testable without a server.
enum NextcloudSearchRequest {

    /// XML-escapes text destined for a `<d:literal>` or href.
    ///
    /// Filenames routinely contain `&`, and a raw ampersand makes the server
    /// reject the whole body as malformed XML — which surfaces as a 400 with no
    /// hint that one search term was responsible.
    static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }

    /// Escapes the wildcard characters SQL `LIKE` treats as syntax, so a search
    /// for a literal `%` or `_` does not match everything.
    static func escapeLikeLiteral(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            if character == "%" || character == "_" || character == "\\" {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }

    static func body(for query: NextcloudQuery, scope: String) -> String {
        let mimeClauses = query.kind.mimePatterns.map { pattern in
            """
            <d:like><d:prop><d:getcontenttype/></d:prop>\
            <d:literal>\(escape(pattern))</d:literal></d:like>
            """
        }

        // A single condition must not be wrapped in <d:or>, which some DAV
        // parsers reject as needing two or more operands.
        let mimeCondition = mimeClauses.count == 1
            ? mimeClauses[0]
            : "<d:or>\(mimeClauses.joined())</d:or>"

        let condition: String
        let term = query.searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        if term.isEmpty {
            condition = mimeCondition
        } else {
            let pattern = "%\(escapeLikeLiteral(term))%"
            condition = """
                <d:and>\(mimeCondition)\
                <d:like><d:prop><d:displayname/></d:prop>\
                <d:literal>\(escape(pattern))</d:literal></d:like></d:and>
                """
        }

        let direction = query.descending ? "<d:descending/>" : "<d:ascending/>"

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <d:searchrequest xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" \
            xmlns:nc="http://nextcloud.org/ns">
              <d:basicsearch>
                <d:select>
                  <d:prop>
                    <d:getcontenttype/>
                    <d:getlastmodified/>
                    <d:getcontentlength/>
                    <d:getetag/>
                    <oc:fileid/>
                    <nc:has-preview/>
                    <nc:metadata-photos-size/>
                    <nc:metadata-photos-original_date_time/>
                    <nc:metadata-blurhash/>
                  </d:prop>
                </d:select>
                <d:from>
                  <d:scope>
                    <d:href>\(escape(scope))</d:href>
                    <d:depth>infinity</d:depth>
                  </d:scope>
                </d:from>
                <d:where>\(condition)</d:where>
                <d:orderby>
                  <d:order>
                    <d:prop><d:\(query.sortField.davProperty)/></d:prop>
                    \(direction)
                  </d:order>
                </d:orderby>
                <d:limit>
                  <d:nresults>\(query.limit)</d:nresults>
                  <nc:firstresult>\(query.offset)</nc:firstresult>
                </d:limit>
              </d:basicsearch>
            </d:searchrequest>
            """
    }
}
