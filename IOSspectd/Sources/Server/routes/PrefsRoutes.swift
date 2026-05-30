// PrefsRoutes.swift - NSUserDefaults plist enumeration.
//
//   GET  /api/apps/{pkg}/prefs       all plist files under
//                                    <data>/Library/Preferences/, each
//                                    decoded into the typed shape the
//                                    web UI's Prefs tab expects.
//   POST /api/apps/{pkg}/prefs/set   upsert a single key in a chosen
//                                    bucket plist. Body:
//                                    { "bucket": "<filename>.plist",
//                                      "key": "...", "value": ...,
//                                      "type": "int|bool|string|float" }

import Foundation

func prefsRoutes(router: Router) {

    router.get("/api/apps/{pkg}/prefs") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg"], status: 400)
        }
        guard let dataDir = FileBrowser.resolveRoot(pkg: pkg, root: .data) else {
            return ctx.json(["error": "data container not found for \(pkg)"], status: 404)
        }
        let raw = PlistReader.readTyped(pkgDataDir: dataDir)
        // Convert TypedEntry to web-UI shape: [{ bucket, keys: [{key, kind, value}] }]
        let buckets: [[String: Any]] = raw.keys.sorted().map { bucket in
            let entries = raw[bucket]!
            let keys: [[String: Any]] = entries.keys.sorted().map { k in
                [
                    "key"  : k,
                    "kind" : entries[k]!.kind,
                    "value": entries[k]!.value
                ]
            }
            return ["bucket": bucket, "keys": keys]
        }
        return ctx.json(["buckets": buckets])
    }

    router.post("/api/apps/{pkg}/prefs/set") { req, ctx in
        // Defense-in-depth: require JSON content type so a cross-origin
        // form-based CSRF can't masquerade as JSON when SameSite=Strict
        // is ever weakened.
        let ct = req.headers["Content-Type"] ?? ""
        guard ct.lowercased().hasPrefix("application/json") else {
            return ctx.json(["error": "expected JSON body"], status: 415)
        }
        guard let pkg = Sanitize.extractPkg(fromPath: req.path),
              let dataDir = FileBrowser.resolveRoot(pkg: pkg, root: .data),
              let body = req.body,
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return ctx.json(["error": "bad request"], status: 400)
        }
        let bucket = json["bucket"] as? String ?? ""
        let key    = json["key"]    as? String ?? ""
        let value  = json["value"]
        let hint   = json["type"]   as? String
        guard !bucket.isEmpty, !key.isEmpty else {
            return ctx.json(["error": "bucket+key required"], status: 400)
        }
        // Validate the bucket. Bare string-concat with an
        // attacker-controlled bucket lets
        // `../../../../var/mobile/Library/IOSspect/sessions.json` write
        // arbitrary plists over root files. Enforce a flat .plist
        // filename only - no separators, no traversal segments - and
        // route the final path through safePathUnder for symlink-safe
        // containment.
        guard bucket.hasSuffix(".plist"),
              !bucket.contains("/"),
              !bucket.contains("\\"),
              !bucket.contains(".."),
              bucket.first != "." else {
            return ctx.json(["error": "invalid bucket name"], status: 400)
        }
        let prefsDir = dataDir + "/Library/Preferences"
        guard (try? Sanitize.safePathUnder(base: prefsDir, relative: bucket)) != nil else {
            return ctx.json(["error": "bucket escapes prefs dir"], status: 400)
        }
        let ok = PlistReader.upsert(pkgDataDir: dataDir, bucket: bucket, key: key, value: value, typeHint: hint)
        return ctx.json(["ok": ok])
    }
}

