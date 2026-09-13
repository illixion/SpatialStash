/*
 Hypnos - Photos Index Query

 Translates `PhotosFilterCriteria` into SQL. Pure string-and-parameter building,
 kept away from the store's plumbing so the interesting part — what each filter
 dimension means — reads in one place.

 The three things PhotoKit could not do, and how they are done here:

 **Filename search** is a `LIKE` against a pre-folded column. PhotoKit has no
 filename predicate key at all, which is what forced the index.

 **Multi-select albums and people** are subqueries against the junction tables,
 and the three `CriterionModifier` cases map exactly onto SQL: `includes` is
 `IN`, `includesAll` is a `GROUP BY … HAVING COUNT(DISTINCT …) = n`, `excludes`
 is `NOT IN`. `fetchAssets(in:)` takes a single collection, so no arrangement of
 PhotoKit calls could answer these.

 **Random** is an ordering over a stored per-asset rank rather than a permutation
 of the result set. That fixes a real defect in the old approach, not just its
 cost: the permutation was seeded against the *result count*, so adding or
 deleting one photo reshuffled the entire library. A stored rank leaves every
 other asset where it was.

 Every ordering ends in `id` as a tiebreak. Without it, rows that compare equal
 can be returned in any order, and `LIMIT/OFFSET` paging over a non-deterministic
 order silently duplicates and skips.
 */

import Foundation
import Photos

struct PhotosIndexQuery {
    let whereSQL: String
    let whereParameters: [SQLValue]
    let orderSQL: String
    let orderParameters: [SQLValue]

    var countSQL: String { "SELECT COUNT(*) FROM asset WHERE \(whereSQL)" }

    var pageSQL: String {
        """
        SELECT id, filename, width, height, duration FROM asset
        WHERE \(whereSQL)
        ORDER BY \(orderSQL)
        LIMIT ? OFFSET ?
        """
    }

    func pageParameters(limit: Int, offset: Int) -> [SQLValue] {
        whereParameters + orderParameters + [.integer(Int64(limit)), .integer(Int64(offset))]
    }
}

enum PhotosIndexQueryBuilder {

    /// Builds the query for one media type.
    ///
    /// `convertedIdentifiers` is the set of assets the app has already produced
    /// 3D output for, resolved by the caller from the depth cache and the
    /// enhancement tracker. It is passed in rather than stored, because those
    /// two are already the authority on it and mirroring them here would be a
    /// third copy of the same fact. Nil means the filter is off; empty means it
    /// is on and nothing qualifies.
    static func build(criteria: PhotosFilterCriteria,
                      mediaType: PHAssetMediaType,
                      convertedIdentifiers: [String]?) -> PhotosIndexQuery {
        var clauses: [String] = ["kind = ?"]
        var parameters: [SQLValue] = [.integer(Int64(mediaType.rawValue))]

        if criteria.favoritesOnly {
            clauses.append("favorite = 1")
        }

        if let subtype = criteria.kind.subtype, criteria.kind.applies(to: mediaType) {
            clauses.append("(subtypes & ?) != 0")
            parameters.append(.integer(Int64(subtype.rawValue)))
        }

        if criteria.dateRangeEnabled {
            if let start = criteria.startDate {
                clauses.append("created >= ?")
                parameters.append(.real(start.timeIntervalSinceReferenceDate))
            }
            if let end = criteria.endDate {
                clauses.append("created <= ?")
                parameters.append(.real(end.timeIntervalSinceReferenceDate))
            }
        }

        let term = criteria.searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            clauses.append("filename_folded LIKE ? ESCAPE '\\'")
            parameters.append(.text("%\(escapeLike(term.lowercased()))%"))
        }

        if let membership = membershipClause(table: "album_asset",
                                             column: "album_id",
                                             ids: criteria.albumIds,
                                             modifier: criteria.albumModifier) {
            clauses.append(membership.sql)
            parameters.append(contentsOf: membership.parameters)
        }

        if let membership = membershipClause(table: "person_asset",
                                             column: "person_id",
                                             ids: criteria.personIds,
                                             modifier: criteria.personModifier) {
            clauses.append(membership.sql)
            parameters.append(contentsOf: membership.parameters)
        }

        if let converted = convertedIdentifiers {
            if converted.isEmpty {
                // The filter is on and nothing qualifies. An empty `IN ()` is a
                // syntax error, so say it directly.
                clauses.append("0")
            } else {
                clauses.append("id IN (\(placeholders(converted.count)))")
                parameters.append(contentsOf: converted.map(SQLValue.text))
            }
        }

        let order = orderClause(criteria: criteria)
        return PhotosIndexQuery(whereSQL: clauses.joined(separator: " AND "),
                                whereParameters: parameters,
                                orderSQL: order.sql,
                                orderParameters: order.parameters)
    }

    // MARK: - Ordering

    private static func orderClause(criteria: PhotosFilterCriteria) -> (sql: String, parameters: [SQLValue]) {
        let descending = criteria.sortDirection == .descending
        let direction = descending ? "DESC" : "ASC"

        switch criteria.sortField {
        case .dateAdded:
            return ("created \(direction), id \(direction)", [])

        case .dateModified:
            return ("modified \(direction), id \(direction)", [])

        case .filename:
            // Un-backfilled rows sort last in both directions rather than
            // clustering at whichever end NULL happens to land on: while the
            // name pass is still running they are "not known yet", not "empty".
            return ("filename_folded IS NULL, filename_folded \(direction), id \(direction)", [])

        case .albumOrder:
            // The manual order only exists relative to one album. With none or
            // several selected there is no such order to follow, so fall back to
            // the library's own.
            guard criteria.albumIds.count == 1, let albumId = criteria.albumIds.first else {
                return ("created DESC, id DESC", [])
            }
            return (
                "(SELECT position FROM album_asset WHERE album_id = ? AND asset_id = asset.id) \(direction), id \(direction)",
                [.text(albumId)]
            )

        case .random:
            // SQLite has no XOR operator, so it is spelled out: for
            // non-negative integers, a ^ b == (a | b) - (a & b). Mixing the rank
            // with the seed gives a different deterministic order per seed while
            // leaving each asset's rank — and so everyone else's position —
            // untouched when the library changes.
            let seed = SQLValue.integer(Int64(abs(criteria.randomSeed ?? 1)))
            return ("((random_rank | ?) - (random_rank & ?)), id", [seed, seed])
        }
    }

    // MARK: - Membership

    private static func membershipClause(table: String,
                                         column: String,
                                         ids: [String],
                                         modifier: CriterionModifier) -> (sql: String, parameters: [SQLValue])? {
        guard !ids.isEmpty else { return nil }
        let list = placeholders(ids.count)
        let values = ids.map(SQLValue.text)

        switch modifier {
        case .includesAll:
            return (
                """
                id IN (SELECT asset_id FROM \(table) WHERE \(column) IN (\(list)) \
                GROUP BY asset_id HAVING COUNT(DISTINCT \(column)) = ?)
                """,
                values + [.integer(Int64(ids.count))]
            )
        case .excludes:
            return ("id NOT IN (SELECT asset_id FROM \(table) WHERE \(column) IN (\(list)))", values)
        default:
            // Every remaining modifier is a Stash-shaped operator with no
            // meaning for set membership; "any of" is the sensible reading.
            return ("id IN (SELECT asset_id FROM \(table) WHERE \(column) IN (\(list)))", values)
        }
    }

    // MARK: - Helpers

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// Escapes the wildcards `LIKE` would otherwise interpret, so searching for
    /// "IMG_0001" does not treat the underscore as "any character".
    private static func escapeLike(_ term: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(term.count)
        for character in term {
            if character == "%" || character == "_" || character == "\\" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
