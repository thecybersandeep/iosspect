// SqliteReader.swift - read-only sqlite browser for an app's databases.
//
// 1. stage(): copy the target .sqlite into the daemon's writable tmp
//    dir so the reader doesn't hold an open fd on the app's data.
// 2. tables(): SELECT name, type FROM sqlite_master.
// 3. rows():  paginated SELECT * FROM <table> LIMIT ? OFFSET ?
// 4. query(): user SELECT. Anything that isn't SELECT is refused.
// 5. csv():   stream rows out as RFC 4180.
//
// libsqlite3 ships on iOS in /usr/lib/libsqlite3.dylib and the iOS SDK
// exposes the `SQLite3` system module map, so import it directly.

import Foundation
import SQLite3

enum SqliteReader {

    struct TableSummary: Codable {
        let name: String
        let type: String
        let rowCount: Int64
    }

    // MARK: - Staging

    /// Copy the source DB to the daemon's tmp dir so opening it doesn't
    /// hold an open fd on the live app file (and so WAL/SHM siblings
    /// don't get touched). Caller owns the cleanup.
    static func stage(srcPath: String) throws -> URL {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosspect-sqlite-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(atPath: srcPath, toPath: dst.path)
        // If sibling WAL/SHM exist, copy them too so the staged DB can
        // see uncommitted pages from the WAL. Best-effort.
        for suffix in ["-wal", "-shm"] {
            let s = srcPath + suffix
            let d = dst.path + suffix
            if FileManager.default.fileExists(atPath: s) {
                try? FileManager.default.copyItem(atPath: s, toPath: d)
            }
        }
        return dst
    }

    // MARK: - Schema

    static func tables(staged: URL) -> [TableSummary] {
        guard let db = open(staged) else { return [] }
        defer { sqlite3_close(db) }
        var out: [TableSummary] = []
        let q = """
            SELECT name, type FROM sqlite_master
            WHERE type IN ('table','view')
              AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let type = String(cString: sqlite3_column_text(stmt, 1))
            out.append(.init(name: name, type: type, rowCount: countRows(db: db, table: name)))
        }
        return out
    }

    // MARK: - Rows

    static func rows(staged: URL, table: String, limit: Int, offset: Int)
        -> (columns: [String], rows: [[Any?]], total: Int64)
    {
        guard let db = open(staged) else { return ([], [], 0) }
        defer { sqlite3_close(db) }
        let total = countRows(db: db, table: table)
        let safe = quoteIdent(table)
        let q = "SELECT * FROM \(safe) LIMIT ? OFFSET ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK else { return ([], [], total) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(min(max(limit, 1), 10_000)))
        sqlite3_bind_int(stmt, 2, Int32(max(offset, 0)))
        return collect(stmt: stmt, total: total)
    }

    // MARK: - Free-form SELECT

    /// User-supplied SELECT. Returns nil for anything that isn't a
    /// straight SELECT or WITH ... SELECT. Defense in depth on top of
    /// SQLITE_OPEN_READONLY: the open flag already blocks writes, but
    /// refusing dangerous statements explicitly is cheap.
    static func query(staged: URL, sql: String, limit: Int)
        -> (columns: [String], rows: [[Any?]], total: Int64)?
    {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        guard upper.hasPrefix("SELECT") || upper.hasPrefix("WITH") else { return nil }
        let banned = ["INSERT ", "UPDATE ", "DELETE ", "DROP ", "ALTER ",
                      "ATTACH ", "DETACH ", "CREATE ", "REPLACE ", "PRAGMA "]
        for b in banned where upper.contains(b) { return nil }

        guard let db = open(staged) else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, trimmed, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let cap = min(max(limit, 1), 10_000)
        return collect(stmt: stmt, total: -1, limit: cap)
    }

    // MARK: - Internals

    private static func open(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        return db
    }

    private static func countRows(db: OpaquePointer?, table: String) -> Int64 {
        let q = "SELECT COUNT(*) FROM \(quoteIdent(table))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW { return sqlite3_column_int64(stmt, 0) }
        return -1
    }

    /// Double-quote a SQL identifier, escaping embedded double-quotes.
    /// SQLite treats "foo""bar" as the single name foo"bar.
    private static func quoteIdent(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Pull every remaining row out of an already-prepared statement.
    /// `limit` of nil means no UI-side cap (driver-side LIMIT already
    /// applied for paginated calls).
    private static func collect(stmt: OpaquePointer?, total: Int64, limit: Int? = nil)
        -> (columns: [String], rows: [[Any?]], total: Int64)
    {
        let ncols = Int(sqlite3_column_count(stmt))
        var columns = [String]()
        columns.reserveCapacity(ncols)
        for i in 0..<ncols {
            columns.append(String(cString: sqlite3_column_name(stmt, Int32(i))))
        }
        var rows: [[Any?]] = []
        let cap = limit ?? Int.max
        while sqlite3_step(stmt) == SQLITE_ROW && rows.count < cap {
            var row: [Any?] = []
            row.reserveCapacity(ncols)
            for i in 0..<ncols {
                row.append(columnValue(stmt: stmt, i: Int32(i)))
            }
            rows.append(row)
        }
        let effectiveTotal = total >= 0 ? total : Int64(rows.count)
        return (columns, rows, effectiveTotal)
    }

    private static func columnValue(stmt: OpaquePointer?, i: Int32) -> Any? {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_NULL:
            return nil
        case SQLITE_INTEGER:
            return sqlite3_column_int64(stmt, i)
        case SQLITE_FLOAT:
            return sqlite3_column_double(stmt, i)
        case SQLITE_TEXT:
            if let p = sqlite3_column_text(stmt, i) {
                return String(cString: p)
            }
            return ""
        case SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, i))
            guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return "blob(0)" }
            let d = Data(bytes: p, count: n)
            // Cap displayed blob preview at 256 bytes so a row of 4MB
            // images doesn't blow up the JSON response. Caller can
            // download the raw file separately.
            let preview = d.prefix(256)
            return "blob(\(n)):" + preview.map { String(format: "%02x", $0) }.joined()
        default:
            return nil
        }
    }
}
