/*
 Hypnos - SQLite Database

 A minimal wrapper over the system `libsqlite3`, sized to exactly what the photo
 index needs and nothing more.

 No dependency: `SQLite3` is a system module on every Apple platform. And no
 SwiftData or Core Data, for a reason specific to what this store *is* — a
 derived cache of the photo library that can always be rebuilt from PhotoKit.
 That makes schema migration `version mismatch → drop → rebuild`, so the whole
 apparatus those frameworks exist to provide is dead weight here.

 Not `Sendable`. Every instance is owned by an actor, which is what serializes
 access; SQLite's own threading modes are deliberately not relied on.
 */

import Foundation
import SQLite3
import os

enum SQLiteError: Error, CustomStringConvertible {
    case open(code: Int32, message: String)
    case prepare(code: Int32, message: String, sql: String)
    case step(code: Int32, message: String)

    var description: String {
        switch self {
        case .open(let code, let message):
            return "open failed (\(code)): \(message)"
        case .prepare(let code, let message, let sql):
            return "prepare failed (\(code)): \(message) — \(sql)"
        case .step(let code, let message):
            return "step failed (\(code)): \(message)"
        }
    }
}

/// A bound parameter. Values arrive from PhotoKit and from filter criteria, so
/// the set is deliberately narrow.
enum SQLValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func bool(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }
    static func optionalText(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    static func optionalDate(_ value: Date?) -> SQLValue {
        value.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null
    }
}

final class SQLiteDatabase {

    private var handle: OpaquePointer?
    /// Statements kept alive between calls. Preparing a statement is the
    /// expensive part of a query, and the indexer runs the same handful of
    /// INSERTs tens of thousands of times.
    private var cachedStatements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError.open(code: result, message: message)
        }
        self.handle = handle

        // WAL keeps a long indexing write from blocking the reads a scrolling
        // grid is making. NORMAL is the right durability trade for a cache that
        // can be rebuilt: a lost transaction on power failure costs re-indexing,
        // never data.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        // Read pages through the page cache rather than copying them in, so a
        // large index stays clean memory rather than dirty pages jetsam counts.
        try execute("PRAGMA mmap_size = 67108864")
    }

    deinit {
        for statement in cachedStatements.values {
            sqlite3_finalize(statement)
        }
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    // MARK: - Execution

    /// Runs one or more statements with no parameters and no results.
    func execute(_ sql: String) throws {
        guard let handle else { return }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorPointer)
            throw SQLiteError.step(code: result, message: message)
        }
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ parameters: [SQLValue] = []) throws {
        let statement = try prepared(sql)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind(parameters, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.step(code: result, message: lastErrorMessage)
        }
    }

    /// Runs a query, handing each row to `readRow`.
    ///
    /// Rows are consumed through a closure rather than materialized into an
    /// array of dictionaries: a page query returns thousands of rows and the
    /// caller always knows its own column layout.
    func query(_ sql: String,
               _ parameters: [SQLValue] = [],
               readRow: (SQLiteRow) throws -> Void) throws {
        let statement = try prepared(sql)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind(parameters, to: statement)
        let row = SQLiteRow(statement: statement)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                try readRow(row)
            } else if result == SQLITE_DONE {
                return
            } else {
                throw SQLiteError.step(code: result, message: lastErrorMessage)
            }
        }
    }

    /// The first column of the first row, as an integer. Nil when no rows.
    func queryInt(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int64? {
        var value: Int64?
        try query(sql, parameters) { row in
            if value == nil { value = row.int64(0) }
        }
        return value
    }

    // MARK: - Transactions

    /// Runs `body` inside a transaction, rolling back if it throws.
    ///
    /// Batching matters more here than usual: inserting 50,000 rows in
    /// autocommit mode is 50,000 fsyncs.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Internals

    private var lastErrorMessage: String {
        guard let handle else { return "no database" }
        return String(cString: sqlite3_errmsg(handle))
    }

    /// Above this many cached statements the cache is dropped wholesale.
    ///
    /// Query SQL is built per filter shape — the `IN (?, ?, ?)` lists vary with
    /// how many albums are selected — so the set of distinct statements grows
    /// slowly over a session rather than converging. A cap keeps that bounded
    /// without giving up caching for the paging queries that do repeat.
    private static let statementCacheLimit = 64

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = cachedStatements[sql] { return cached }
        if cachedStatements.count >= Self.statementCacheLimit {
            for statement in cachedStatements.values {
                sqlite3_finalize(statement)
            }
            cachedStatements.removeAll(keepingCapacity: true)
        }
        guard let handle else {
            throw SQLiteError.prepare(code: SQLITE_MISUSE, message: "no database", sql: sql)
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteError.prepare(code: result, message: lastErrorMessage, sql: sql)
        }
        cachedStatements[sql] = statement
        return statement
    }

    private func bind(_ parameters: [SQLValue], to statement: OpaquePointer) throws {
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let number):
                result = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                result = sqlite3_bind_double(statement, index, number)
            case .text(let string):
                result = sqlite3_bind_text(statement, index, string, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                result = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
            }
            guard result == SQLITE_OK else {
                throw SQLiteError.step(code: result, message: lastErrorMessage)
            }
        }
    }
}

/// One row of a result set, valid only inside the `readRow` closure.
struct SQLiteRow {
    let statement: OpaquePointer

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func bool(_ column: Int32) -> Bool { sqlite3_column_int64(statement, column) != 0 }

    func string(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    func data(_ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return Data(bytes: pointer, count: count)
    }

    func date(_ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
    }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }
}

/// `SQLITE_TRANSIENT` is a function-pointer sentinel that Swift's importer does
/// not surface, so it is reconstructed here. Without it, bound strings and blobs
/// are assumed to outlive the statement — which they do not.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
