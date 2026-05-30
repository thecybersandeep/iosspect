// AssetRoutes.swift - serve the bundled SPA from WebAssets.path.
// Path traversal guard: resolve the request path against the web root,
// then reject anything that escapes the prefix.

import Foundation

func assetRoutes(router: Router) {
    // Index
    router.get("/") { _, _ in serveFile("index.html") }
    router.get("/index.html") { _, _ in serveFile("index.html") }
    // Other static files. Pattern `/*` is the wildcard the router
    // understands; the handler reads the actual path from req.path.
    router.get("/*") { req, _ in serveFile(String(req.path.dropFirst())) }
}

private func serveFile(_ relative: String) -> HTTPResponse {
    let root = WebAssets.path
    // Resolve and verify the file stays under root.
    let target = (root as NSString).appendingPathComponent(relative)
    let canonical = (target as NSString).standardizingPath
    guard canonical.hasPrefix(root) else {
        return HTTPResponse(status: 400, headers: ["Content-Type": "text/plain"],
                            body: .bytes(Data("bad path".utf8)))
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: canonical)) else {
        return HTTPResponse(status: 404, headers: ["Content-Type": "text/plain"],
                            body: .bytes(Data("not found: \(relative)".utf8)))
    }
    return HTTPResponse(
        status: 200,
        headers: [
            "Content-Type": mimeFor(relative),
            "Cache-Control": "no-store",
            "Connection": "close"
        ],
        body: .bytes(data)
    )
}

private func mimeFor(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "html", "htm": return "text/html; charset=utf-8"
    case "js":          return "application/javascript; charset=utf-8"
    case "css":         return "text/css; charset=utf-8"
    case "svg":         return "image/svg+xml"
    case "png":         return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "json":        return "application/json"
    default:            return "application/octet-stream"
    }
}
