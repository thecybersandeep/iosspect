// FileRoutes.swift - file browser for the selected app's data container
// and its bundle. One endpoint serves both roots, switched by
// ?root=data|bundle.

import Foundation
import UIKit

func fileRoutes(router: Router) {
    router.get("/api/apps/{pkg}/files") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg in path"], status: 400)
        }
        let rel = req.query["path"] ?? ""
        let rootKind = FileBrowser.RootKind(rawValue: req.query["root"] ?? "data") ?? .data
        do {
            let (root, entries) = try FileBrowser.list(pkg: pkg, relative: rel, root: rootKind)
            return ctx.json([
                "root"     : root,
                "relative" : rel,
                "entries"  : entries.map { [
                    "name"      : $0.name,
                    "path"      : $0.path,
                    "isDir"     : $0.isDir,
                    "size"      : $0.size,
                    "modifiedMs": $0.modifiedMs,
                    "kind"      : $0.kind
                ] }
            ])
        } catch {
            return ctx.json(["error": "\(error.localizedDescription)"], status: 404)
        }
    }

    router.get("/api/apps/{pkg}/files/raw") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg in path"], status: 400)
        }
        let rel = req.query["path"] ?? ""
        let rootKind = FileBrowser.RootKind(rawValue: req.query["root"] ?? "data") ?? .data
        do {
            let data = try FileBrowser.readBytes(pkg: pkg, relative: rel, root: rootKind)
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

    router.get("/api/apps/{pkg}/files/text") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg in path"], status: 400)
        }
        let rel = req.query["path"] ?? ""
        let rootKind = FileBrowser.RootKind(rawValue: req.query["root"] ?? "data") ?? .data
        do {
            // 512 KB cap on text preview. JSON escaping roughly 20x's
            // the wire size for binaryish content, so a higher cap lets
            // a handful of concurrent previews OOM the daemon.
            let data = try FileBrowser.readBytes(pkg: pkg, relative: rel, root: rootKind, max: 512_000)
            let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? "(binary, \(data.count) bytes)"
            return ctx.json(["path": rel, "text": text, "size": data.count])
        } catch {
            return ctx.json(["error": "\(error.localizedDescription)"], status: 404)
        }
    }

    router.get("/api/apps/{pkg}/files/hex") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg in path"], status: 400)
        }
        let rel = req.query["path"] ?? ""
        let rootKind = FileBrowser.RootKind(rawValue: req.query["root"] ?? "data") ?? .data
        do {
            let data = try FileBrowser.readBytes(pkg: pkg, relative: rel, root: rootKind, max: 256_000)
            let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            return ctx.json(["path": rel, "hex": hex, "size": data.count])
        } catch {
            return ctx.json(["error": "\(error.localizedDescription)"], status: 404)
        }
    }

    // Plist preview. Handles both binary (bplist00) and XML plists via
    // PropertyListSerialization. We send back two views: a JSON-decoded
    // tree (so the UI can render a typed key/value table) and a pretty
    // XML string (so the user can copy/paste raw if they want).
    router.get("/api/apps/{pkg}/files/plist") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg in path"], status: 400)
        }
        let rel = req.query["path"] ?? ""
        let rootKind = FileBrowser.RootKind(rawValue: req.query["root"] ?? "data") ?? .data
        do {
            let data = try FileBrowser.readBytes(pkg: pkg, relative: rel, root: rootKind, max: 4_000_000)
            guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) else {
                // Not a valid plist after all. Fall back to a hex dump
                // so the user at least sees something instead of an error.
                let hex = data.prefix(2048).map { String(format: "%02x", $0) }.joined(separator: " ")
                return ctx.json([
                    "path"  : rel,
                    "size"  : data.count,
                    "kind"  : "invalid",
                    "hex"   : hex,
                    "error" : "not a valid plist"
                ])
            }
            // Round-trip back to XML so the user can see the canonical form.
            let xmlData = (try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )) ?? Data()
            let xml = String(data: xmlData, encoding: .utf8) ?? ""
            // Top-level decode for the tree view.
            let tree = anyToJSONSafe(plist)
            return ctx.json([
                "path" : rel,
                "size" : data.count,
                "tree" : tree,
                "xml"  : xml
            ])
        } catch {
            return ctx.json(["error": "\(error.localizedDescription)"], status: 404)
        }
    }

    // Image preview that always returns PNG. The browser can render PNG
    // natively for anything UIImage understands, including .ktx snapshot
    // files iOS writes to Library/Caches/Snapshots/ that a raw <img src>
    // cannot decode on its own. Browser-native formats round-trip
    // through UIImage too; the cost is small.
    router.get("/api/apps/{pkg}/files/image") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg in path"], status: 400)
        }
        let rel = req.query["path"] ?? ""
        let rootKind = FileBrowser.RootKind(rawValue: req.query["root"] ?? "data") ?? .data
        do {
            // Cap at 32 MB. Snapshots can be a few MB each, framework
            // image assets occasionally a few tens of MB.
            let data = try FileBrowser.readBytes(pkg: pkg, relative: rel, root: rootKind, max: 32_000_000)
            guard let img = UIImage(data: data) else {
                return ctx.json([
                    "error" : "UIImage could not decode \(rel) (\(data.count) bytes)"
                ], status: 415)
            }
            guard let png = img.pngData() else {
                return ctx.json(["error": "PNG encode failed"], status: 500)
            }
            var r = HTTPResponse()
            r.status = 200
            r.headers = [
                "Content-Type"  : "image/png",
                "Cache-Control" : "no-store",
                "Connection"    : "close"
            ]
            r.body = .bytes(png)
            return r
        } catch {
            return ctx.json(["error": "\(error.localizedDescription)"], status: 404)
        }
    }

    // Recursive content grep. Walks the directory under `path`, scans
    // every file under a small size cap as UTF-8, returns the first
    // matching line per hit. Capped at 200 hits / 5 MB per file so a
    // careless pattern doesn't hang the daemon.
    router.get("/api/apps/{pkg}/files/grep") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg"], status: 400)
        }
        let rel = req.query["path"] ?? ""
        let q   = req.query["q"]    ?? ""
        let lim = Int(req.query["limit"] ?? "200") ?? 200
        let rootKind = FileBrowser.RootKind(rawValue: req.query["root"] ?? "data") ?? .data
        guard !q.isEmpty else { return ctx.json(["error": "missing q"], status: 400) }
        guard let base = FileBrowser.resolveRoot(pkg: pkg, root: rootKind),
              let start = try? Sanitize.safePathUnder(base: base, relative: rel) else {
            return ctx.json(["error": "no \(rootKind.rawValue) container for \(pkg)"], status: 404)
        }
        var hits: [[String: Any]] = []
        var total = 0
        let fm = FileManager.default
        // BFS rather than the depth-first enumerator so a flat tail of a
        // huge subtree doesn't starve other branches.
        var stack: [String] = [start]
        while let dir = stack.popLast(), hits.count < lim {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries.sorted() {
                if hits.count >= lim { break }
                let full = "\(dir)/\(name)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue { stack.append(full); continue }
                // Skip obviously-binary or huge files cheaply.
                let attrs = (try? fm.attributesOfItem(atPath: full)) ?? [:]
                let sz = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                if sz > 5_000_000 { continue }
                guard let raw = try? Data(contentsOf: URL(fileURLWithPath: full)),
                      let text = String(data: raw, encoding: .utf8) else { continue }
                // localizedCaseInsensitiveContains avoids allocating a
                // second copy of every candidate file just to lowercase it.
                guard text.localizedCaseInsensitiveContains(q) else { continue }
                // First matching line, trimmed for the sample.
                let line = text.split(separator: "\n").first(where: { $0.localizedCaseInsensitiveContains(q) })
                            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                let snippet = line.count > 240 ? String(line.prefix(240)) + "..." : line
                let relPath = String(full.dropFirst(base.count + 1))
                hits.append(["relative": relPath, "sample": snippet])
                total += 1
            }
        }
        return ctx.json([
            "root"  : base,
            "total" : total,
            "hits"  : hits
        ])
    }

    // ZIP a directory under the chosen root. Pure-Swift writer using the
    // STORE method (no compression) so we don't need libz from Swift. The
    // resulting archive opens cleanly in any unzip implementation.
    router.get("/api/apps/{pkg}/files/zip") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg"], status: 400)
        }
        let rel = req.query["path"] ?? ""
        let rootKind = FileBrowser.RootKind(rawValue: req.query["root"] ?? "data") ?? .data
        guard let base = FileBrowser.resolveRoot(pkg: pkg, root: rootKind),
              let dir  = try? Sanitize.safePathUnder(base: base, relative: rel) else {
            return ctx.json(["error": "no \(rootKind.rawValue) container for \(pkg)"], status: 404)
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosspect-zip-\(UUID().uuidString).zip")
        guard ZipWriter.writeDirectory(root: dir,
                                        baseLabel: (dir as NSString).lastPathComponent,
                                        out: out) != nil else {
            try? FileManager.default.removeItem(at: out)
            return ctx.json(["error": "zip failed"], status: 500)
        }
        var r = HTTPResponse()
        r.status = 200
        let fname = "\(pkg)\(rel.isEmpty ? "" : "_\(rel.replacingOccurrences(of: "/", with: "_"))").zip"
        r.headers = [
            "Content-Type"       : "application/zip",
            "Content-Disposition": "attachment; filename=\"\(fname)\"",
            "Cache-Control"      : "no-store",
            "Connection"         : "close"
        ]
        r.body = .file(out)
        return r
    }
}

/// Recursively coerce a decoded plist value into something JSONSerialization
/// can encode. Dates -> ISO 8601, Data -> base64, nested types recurse.
private func anyToJSONSafe(_ v: Any) -> Any {
    if let d = v as? [String: Any] { return d.mapValues { anyToJSONSafe($0) } }
    if let a = v as? [Any]         { return a.map { anyToJSONSafe($0) } }
    if let s = v as? String        { return s }
    if let n = v as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return n
    }
    if let date = v as? Date {
        let f = ISO8601DateFormatter()
        return f.string(from: date)
    }
    if let data = v as? Data {
        // Cap at 32 KB so a giant blob doesn't blow up the preview.
        let capped = data.prefix(32 * 1024)
        return ["__data__": capped.base64EncodedString(),
                "bytes"   : data.count]
    }
    return "\(v)"
}

/// Pulls `<pkg>` out of `/api/apps/<pkg>/...` and validates it as a
/// bundle id. Returns nil if the path doesn't conform or the value
/// fails the bundle-id regex.
