// ManifestRoutes.swift - iOS app metadata endpoints.
//
//   /api/apps/{pkg}/manifest    decoded Info.plist. Called "manifest"
//                               on the wire for parity with the wider
//                               toolset; the UI label is "Plist".

import Foundation

func manifestRoutes(router: Router) {
    router.get("/api/apps/{pkg}/manifest") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg"], status: 400)
        }
        guard let bundle = FileBrowser.resolveRoot(pkg: pkg, root: .bundle) else {
            return ctx.json(["error": "bundle not found for \(pkg)"], status: 404)
        }
        let infoPath = bundle + "/Info.plist"
        guard let raw = NSDictionary(contentsOfFile: infoPath) as? [String: Any] else {
            return ctx.json(["error": "Info.plist unreadable"], status: 404)
        }

        // Build summary chips for the header (matches the iOS-pentest
        // mindset: bundle id, version, min OS, URL schemes count,
        // background modes, app groups, privacy strings count).
        let urlSchemes = collectURLSchemes(raw)
        let bgModes    = (raw["UIBackgroundModes"] as? [String]) ?? []
        let appGroups  = (raw["com.apple.security.application-groups"] as? [String]) ?? []
        let privacy    = raw.keys.filter { $0.hasSuffix("UsageDescription") }.sorted()

        let summary: [String: Any] = [
            "bundleId"        : raw["CFBundleIdentifier"]          ?? "",
            "displayName"     : raw["CFBundleDisplayName"]         ?? raw["CFBundleName"] ?? "",
            "shortVersion"    : raw["CFBundleShortVersionString"]  ?? "",
            "buildVersion"    : raw["CFBundleVersion"]             ?? "",
            "minimumOSVersion": raw["MinimumOSVersion"]            ?? "",
            "executable"      : raw["CFBundleExecutable"]          ?? "",
            "urlSchemes"      : urlSchemes,
            "backgroundModes" : bgModes,
            "appGroups"       : appGroups,
            "privacyKeys"     : privacy
        ]
        // Full decoded plist for the lower panel (so pentester can see
        // EVERY key, not just the ones we extracted).
        let full = (PlistReader.decodeFile(infoPath) ?? [:])
            .mapValues { ["kind": $0.kind, "value": $0.value] as [String: Any] }
        return ctx.json([
            "summary": summary,
            "info"   : full
        ])
    }

    router.get("/api/apps/{pkg}/components") { _, ctx in
        // iOS doesn't have Android's four-component model. We surface
        // the equivalents (URL schemes, extensions, queries scheme list)
        // inside the manifest endpoint above. Keep this 410-Gone so the
        // web UI can hide its Components tab cleanly.
        ctx.json(["error": "not applicable on iOS - see /manifest"], status: 410)
    }

    router.get("/api/apps/{pkg}/native") { req, ctx in
        // Walk the bundle and probe every Mach-O for arch / strip /
        // encryption state. NativeLibScanner covers main binary,
        // Frameworks/*.dylib, Frameworks/*.framework, PlugIns/*.appex.
        guard let pkg = Sanitize.extractPkg(fromPath: req.path),
              let bundle = FileBrowser.resolveRoot(pkg: pkg, root: .bundle) else {
            return ctx.json(["error": "bad pkg or bundle missing"], status: 404)
        }
        let libs = NativeLibScanner.scan(bundlePath: bundle)
        let json: [[String: Any]] = libs.map {
            ["name": $0.name, "path": $0.path, "size": $0.size,
             "arch": $0.arch, "stripped": $0.stripped, "encrypted": $0.encrypted]
        }
        return ctx.json(["libs": json])
    }

    // Stream the raw bytes of any binary the scanner surfaced. The path
    // query is interpreted as relative to the bundle root and validated
    // through Sanitize.safePathUnder. A plain hasPrefix(bundle) check
    // on an absolute path would let `<bundle>/../../etc/passwd` slip
    // through.
    router.get("/api/apps/{pkg}/native/raw") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path),
              let bundle = FileBrowser.resolveRoot(pkg: pkg, root: .bundle) else {
            return ctx.json(["error": "bad pkg or bundle missing"], status: 404)
        }
        let raw = req.query["path"] ?? ""
        // Accept either an absolute path under the bundle (legacy JS) or
        // a relative path. We rebase absolutes onto the bundle root and
        // then validate via safePathUnder.
        let relative: String
        if raw.hasPrefix(bundle) {
            relative = String(raw.dropFirst(bundle.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            relative = raw
        }
        guard let target = try? Sanitize.safePathUnder(base: bundle, relative: relative) else {
            return ctx.json(["error": "path escapes bundle"], status: 400)
        }
        // Cap file size at 200 MB to avoid an authenticated attacker
        // streaming `/dev/zero`-equivalents and OOMing the daemon.
        let attrs = (try? FileManager.default.attributesOfItem(atPath: target)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= 200_000_000 else {
            return ctx.json(["error": "file too large"], status: 413)
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target)) else {
            return ctx.json(["error": "cannot read"], status: 404)
        }
        var r = HTTPResponse()
        r.status = 200
        r.headers = [
            "Content-Type"       : "application/octet-stream",
            "Content-Disposition": "attachment; filename=\"\((target as NSString).lastPathComponent)\"",
            "Cache-Control"      : "no-store",
            "Connection"         : "close"
        ]
        r.body = .bytes(data)
        return r
    }
}

private func collectURLSchemes(_ info: [String: Any]) -> [String] {
    var schemes: [String] = []
    if let types = info["CFBundleURLTypes"] as? [[String: Any]] {
        for t in types {
            if let s = t["CFBundleURLSchemes"] as? [String] {
                schemes.append(contentsOf: s)
            }
        }
    }
    if let queried = info["LSApplicationQueriesSchemes"] as? [String] {
        for q in queried { if !schemes.contains(q) { schemes.append(q) } }
    }
    return schemes.sorted()
}
