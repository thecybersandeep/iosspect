// SqliteRoutes.swift - SQLite reader endpoints. iOS ships libsqlite3 in
// /usr/lib. The reader stages a copy into the daemon's tmp dir, opens
// it with SQLITE_OPEN_READONLY, and never touches the original.
import Foundation

func sqliteRoutes(router: Router) {

    router.get("/api/apps/{pkg}/sqlite/tables") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg in path"], status: 400)
        }
        let rel = req.query["path"] ?? ""
        let rootKind = FileBrowser.RootKind(rawValue: req.query["root"] ?? "data") ?? .data
        guard let abs = resolvePath(pkg: pkg, relative: rel, root: rootKind) else {
            return ctx.json(["error": "no \(rootKind.rawValue) container for \(pkg)"], status: 404)
        }
        do {
            let staged = try SqliteReader.stage(srcPath: abs)
            defer { cleanup(staged) }
            let tables = SqliteReader.tables(staged: staged)
            return ctx.json([
                "path"   : rel,
                "tables" : tables.map { [
                    "name"     : $0.name,
                    "type"     : $0.type,
                    "rowCount" : $0.rowCount
                ] }
            ])
        } catch {
            return ctx.json(["error": "\(error.localizedDescription)"], status: 500)
        }
    }

    router.get("/api/apps/{pkg}/sqlite/rows") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg in path"], status: 400)
        }
        let rel = req.query["path"] ?? ""
        let rootKind = FileBrowser.RootKind(rawValue: req.query["root"] ?? "data") ?? .data
        guard let table = req.query["table"], !table.isEmpty else {
            return ctx.json(["error": "missing table"], status: 400)
        }
        let limit  = Int(req.query["limit"]  ?? "100") ?? 100
        let offset = Int(req.query["offset"] ?? "0")   ?? 0
        guard let abs = resolvePath(pkg: pkg, relative: rel, root: rootKind) else {
            return ctx.json(["error": "no \(rootKind.rawValue) container for \(pkg)"], status: 404)
        }
        do {
            let staged = try SqliteReader.stage(srcPath: abs)
            defer { cleanup(staged) }
            let (columns, rows, total) = SqliteReader.rows(staged: staged,
                                                           table: table,
                                                           limit: limit,
                                                           offset: offset)
            return ctx.json([
                "path"    : rel,
                "table"   : table,
                "columns" : columns,
                "rows"    : rows.map { rowToJSONSafe($0) },
                "total"   : total,
                "limit"   : limit,
                "offset"  : offset
            ])
        } catch {
            return ctx.json(["error": "\(error.localizedDescription)"], status: 500)
        }
    }

    router.post("/api/apps/{pkg}/sqlite/query") { req, ctx in
        let ct = req.headers["Content-Type"] ?? ""
        guard ct.lowercased().hasPrefix("application/json") else {
            return ctx.json(["error": "expected JSON body"], status: 415)
        }
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg in path"], status: 400)
        }
        let rel = req.query["path"] ?? ""
        let rootKind = FileBrowser.RootKind(rawValue: req.query["root"] ?? "data") ?? .data
        let limit = Int(req.query["limit"] ?? "500") ?? 500
        // Body is JSON: {"sql": "SELECT ..."}
        guard let body = req.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let sql  = json["sql"] as? String, !sql.isEmpty else {
            return ctx.json(["error": "POST body must be JSON {\"sql\": \"SELECT ...\"}"], status: 400)
        }
        guard let abs = resolvePath(pkg: pkg, relative: rel, root: rootKind) else {
            return ctx.json(["error": "no \(rootKind.rawValue) container for \(pkg)"], status: 404)
        }
        do {
            let staged = try SqliteReader.stage(srcPath: abs)
            defer { cleanup(staged) }
            guard let (columns, rows, total) = SqliteReader.query(staged: staged, sql: sql, limit: limit) else {
                return ctx.json([
                    "error": "only SELECT / WITH ... SELECT queries are allowed"
                ], status: 400)
            }
            return ctx.json([
                "path"    : rel,
                "sql"     : sql,
                "columns" : columns,
                "rows"    : rows.map { rowToJSONSafe($0) },
                "total"   : total,
                "limit"   : limit
            ])
        } catch {
            return ctx.json(["error": "\(error.localizedDescription)"], status: 500)
        }
    }

    router.get("/api/apps/{pkg}/sqlite/download") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg in path"], status: 400)
        }
        let rel = req.query["path"] ?? ""
        let rootKind = FileBrowser.RootKind(rawValue: req.query["root"] ?? "data") ?? .data
        do {
            let data = try FileBrowser.readBytes(pkg: pkg, relative: rel, root: rootKind, max: 100_000_000)
            var r = HTTPResponse()
            r.status = 200
            r.headers = [
                "Content-Type"       : "application/octet-stream",
                "Content-Disposition": "attachment; filename=\"\((rel as NSString).lastPathComponent)\"",
                "Cache-Control"      : "no-store",
                "Connection"         : "close"
            ]
            r.body = .bytes(data)
            return r
        } catch {
            return ctx.json(["error": "\(error.localizedDescription)"], status: 404)
        }
    }

    // CSV export. Body: {"path": "<rel>", "sql": "..."} OR
    // {"path": "<rel>", "table": "..."}. Returns a text/csv body, the
    // UI saves it as <table or 'query'>.csv.
    router.post("/api/apps/{pkg}/sqlite/csv") { req, ctx in
        let ct = req.headers["Content-Type"] ?? ""
        guard ct.lowercased().hasPrefix("application/json") else {
            return ctx.json(["error": "expected JSON body"], status: 415)
        }
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg"], status: 400)
        }
        let rootKind = FileBrowser.RootKind(rawValue: req.query["root"] ?? "data") ?? .data
        guard let body = req.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let rel  = json["path"] as? String else {
            return ctx.json(["error": "POST body must be JSON {path, sql|table}"], status: 400)
        }
        let limit = (json["limit"] as? Int) ?? 10_000
        guard let abs = resolvePath(pkg: pkg, relative: rel, root: rootKind) else {
            return ctx.json(["error": "no \(rootKind.rawValue) container for \(pkg)"], status: 404)
        }
        do {
            let staged = try SqliteReader.stage(srcPath: abs)
            defer { cleanup(staged) }
            let result: (columns: [String], rows: [[Any?]], total: Int64)?
            var fname = "query"
            if let sql = json["sql"] as? String, !sql.isEmpty {
                result = SqliteReader.query(staged: staged, sql: sql, limit: limit)
            } else if let table = json["table"] as? String, !table.isEmpty {
                fname = table
                let r = SqliteReader.rows(staged: staged, table: table, limit: limit, offset: 0)
                result = (r.columns, r.rows, r.total)
            } else {
                return ctx.json(["error": "need either sql or table in body"], status: 400)
            }
            guard let r = result else {
                return ctx.json(["error": "only SELECT / WITH ... SELECT queries are allowed"], status: 400)
            }
            let csv = rowsToCSV(columns: r.columns, rows: r.rows)
            var resp = HTTPResponse()
            resp.status = 200
            resp.headers = [
                "Content-Type"       : "text/csv; charset=utf-8",
                "Content-Disposition": "attachment; filename=\"\(fname).csv\"",
                "Cache-Control"      : "no-store",
                "Connection"         : "close"
            ]
            resp.body = .bytes(Data(csv.utf8))
            return resp
        } catch {
            return ctx.json(["error": "\(error.localizedDescription)"], status: 500)
        }
    }
}

/// Minimal RFC 4180 CSV encoder. Quotes any field that contains a
/// comma, quote, newline, or carriage return; doubles embedded quotes.
private func rowsToCSV(columns: [String], rows: [[Any?]]) -> String {
    var out = ""
    out.reserveCapacity(rows.count * columns.count * 16)
    out.append(columns.map { csvField($0) }.joined(separator: ","))
    out.append("\r\n")
    for row in rows {
        let line = row.map { v -> String in
            guard let v = v else { return "" }
            if let i = v as? Int64  { return String(i) }
            if let d = v as? Double { return String(d) }
            return csvField("\(v)")
        }.joined(separator: ",")
        out.append(line)
        out.append("\r\n")
    }
    return out
}

private func csvField(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return s
}

// MARK: - Helpers

/// Resolve a user-supplied relative path inside the chosen root to an
/// absolute on-disk path, with the same containment check the file
/// browser uses. Returns nil on any error (missing container, escape).
private func resolvePath(pkg: String, relative: String, root: FileBrowser.RootKind) -> String? {
    guard let base = FileBrowser.resolveRoot(pkg: pkg, root: root) else { return nil }
    return try? Sanitize.safePathUnder(base: base, relative: relative)
}

/// Convert one row's worth of mixed Swift values into something
/// JSONSerialization can encode. Int64 stays Int64 (JSONSerialization
/// handles NSNumber). Data -> base64, nil -> NSNull. Blobs already
/// came back as strings from SqliteReader.
private func rowToJSONSafe(_ row: [Any?]) -> [Any] {
    row.map { v -> Any in
        guard let v = v else { return NSNull() }
        if let i = v as? Int64  { return NSNumber(value: i) }
        if let d = v as? Double { return NSNumber(value: d) }
        if let s = v as? String { return s }
        if let d = v as? Data   { return d.base64EncodedString() }
        return "\(v)"
    }
}

/// Best-effort cleanup of a staged DB plus its WAL/SHM sidecars.
private func cleanup(_ url: URL) {
    let fm = FileManager.default
    try? fm.removeItem(at: url)
    for s in ["-wal", "-shm"] {
        try? fm.removeItem(atPath: url.path + s)
    }
}
