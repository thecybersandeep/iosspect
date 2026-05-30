// AppRoutes.swift - /api/apps. Backed by AppDataReader (MobileInstall-
// ation plist + LSApplicationWorkspace fallback).
import Foundation

func appRoutes(router: Router) {
    router.get("/api/apps") { req, ctx in
        let includeSystem = req.query["system"] == "1"
        let q = req.query["q"]?.lowercased()
        let list = AppDataReader.shared.installedApps(includeSystem: includeSystem)
        let filtered: [[String: Any]]
        if let q, !q.isEmpty {
            filtered = list.filter {
                ($0["label"] as? String ?? "").lowercased().contains(q) ||
                ($0["packageName"] as? String ?? "").lowercased().contains(q)
            }
        } else { filtered = list }
        return ctx.json(filtered)
    }

    // Download the app bundle as an IPA. Wraps <bundle>/<App>.app in
    // Payload/<App>.app/. The main binary is still FairPlay-encrypted
    // on App Store installs - fine for static inspection, not directly
    // sideloadable via TrollStore (CoreTrust needs a decrypted Mach-O).
    router.get("/api/apps/{pkg}/apk") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg"], status: 400)
        }
        guard let ipaURL = AppActions.pullIPA(bundleId: pkg) else {
            return ctx.json(["error": "bundle not found for \(pkg)"], status: 404)
        }
        var r = HTTPResponse()
        r.status = 200
        r.headers = [
            "Content-Type"       : "application/octet-stream",
            "Content-Disposition": "attachment; filename=\"\(pkg).ipa\"",
            "Cache-Control"      : "no-store",
            "Connection"         : "close"
        ]
        // Router streams .file in 1 MB chunks and deletes the temp when done.
        r.body = .file(ipaURL)
        return r
    }
}
