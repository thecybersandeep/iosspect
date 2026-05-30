// Router.swift - HTTP router + HTTP/1.1 connection handler.
// Hand-rolled (no NIO / Hummingbird / Vapor) for the reasons covered in
// IOSspectServer.swift.
//
// What's here:
//   - Router: register get / post handlers by path
//   - HTTPRequest / HTTPResponse: dumb POD types
//   - HTTPConnection.handle: parse a request, dispatch to a handler,
//     write the response, recycle for keep-alive
//   - Auth gate: every route that isn't asset / login is cookie-checked
//
// Streaming bodies (file downloads, ZIP) are returned by route handlers
// as a `.stream` or `.file` body so the router stays untyped about the
// payload.

import Foundation
import Network

// MARK: - Public surface

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data?
    let remoteIP: String?
}

struct HTTPResponse {
    var status: Int = 200
    var headers: [String: String] = [
        "Content-Type": "application/json",
        "Connection": "close"
    ]
    var body: Body = .empty
    enum Body {
        case empty
        case bytes(Data)
        case stream((@escaping (Data) -> Void, @escaping () -> Void) -> Void)
        /// File on disk that should be streamed in chunks instead of
        /// materialising the whole payload in memory. Path is deleted
        /// after the response is fully sent. Use for IPA / dir-zip
        /// downloads where the payload can be >100 MB.
        case file(URL)
    }
}

struct HandlerContext {
    weak var router: Router?
    func json(_ value: Any, status: Int = 200) -> HTTPResponse {
        var r = HTTPResponse()
        r.status = status
        r.headers["Content-Type"] = "application/json; charset=utf-8"
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        r.body = .bytes(data)
        return r
    }
    func text(_ s: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        var r = HTTPResponse()
        r.status = status
        r.headers["Content-Type"] = contentType
        r.body = .bytes(Data(s.utf8))
        return r
    }
    func notImplemented(_ note: String = "TODO") -> HTTPResponse {
        json(["error": "not implemented", "note": note], status: 501)
    }
}

final class Router {

    typealias Handler = (HTTPRequest, HandlerContext) -> HTTPResponse

    private struct Route { let method: String; let pattern: String; let handler: Handler }
    private var routes: [Route] = []
    weak var security: SecurityManager?

    // Paths that bypass the auth cookie. Anything not on this list
    // requires a valid session.
    private let openPaths: Set<String> = [
        "/api/auth/login",
        "/",            // index.html for the login overlay
        "/app.js", "/app.css", "/icon.svg",
        "/index.html"
    ]

    func get(_ pattern: String, handler: @escaping Handler) {
        routes.append(.init(method: "GET", pattern: pattern, handler: handler))
    }
    func post(_ pattern: String, handler: @escaping Handler) {
        routes.append(.init(method: "POST", pattern: pattern, handler: handler))
    }
    func ws(_ pattern: String, handler: @escaping Handler) {
        // WebSocket routes share the GET method; the handler does the
        // upgrade dance itself.
        routes.append(.init(method: "GET", pattern: pattern, handler: handler))
    }

    func dispatch(_ req: HTTPRequest, security: SecurityManager) -> HTTPResponse {
        // Auth gate. Open paths skip it. /scripts/* is open so the user
        // can `curl` the Frida JS helpers (keychain-dump.js etc.) from
        // a terminal without going through the dashboard.
        let isOpen = openPaths.contains(req.path)
            || req.path.hasPrefix("/api/auth/")
            || req.path.hasPrefix("/scripts/")
        if !isOpen {
            if !security.authorize(cookieHeader: req.headers["Cookie"]) {
                let ctx = HandlerContext(router: self)
                return ctx.json(["error": "auth required"], status: 401)
            }
        }
        for r in routes where r.method == req.method {
            if matches(pattern: r.pattern, path: req.path) {
                return r.handler(req, HandlerContext(router: self))
            }
        }
        let ctx = HandlerContext(router: self)
        return ctx.json(["error": "not found", "path": req.path], status: 404)
    }

    /// Trivial matcher: exact equality, or pattern ending in `/*` for
    /// wildcard prefix matching (used by the asset route). Full path
    /// variables (`:pkg`) get resolved by the route handler reading
    /// req.path manually for now. Cheap, no regex.
    private func matches(pattern: String, path: String) -> Bool {
        if pattern == path { return true }
        if pattern.hasSuffix("/*") {
            let prefix = String(pattern.dropLast(1))
            return path.hasPrefix(prefix)
        }
        // Allow path-variable patterns like `/api/apps/{pkg}/manifest`.
        // The pattern segments equal `{*}` match any segment.
        let pp = pattern.split(separator: "/")
        let qq = path.split(separator: "/")
        guard pp.count == qq.count else { return false }
        for (a, b) in zip(pp, qq) {
            if a.hasPrefix("{") && a.hasSuffix("}") { continue }
            if a != b { return false }
        }
        return true
    }
}

// MARK: - HTTP/1.1 connection

enum HTTPConnection {

    static func handle(_ conn: NWConnection,
                       router: Router,
                       security: SecurityManager,
                       webRoot: String) {
        router.security = security
        let q = DispatchQueue(label: "iosspect.conn")
        conn.start(queue: q)
        readRequest(conn) { req in
            guard let req else { conn.cancel(); return }
            let resp = router.dispatch(req, security: security)
            write(conn: conn, resp: resp) { conn.cancel() }
        }
    }

    /// Read until end-of-headers, then optionally a Content-Length body.
    private static func readRequest(_ conn: NWConnection, completion: @escaping (HTTPRequest?) -> Void) {
        var buffer = Data()
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, err in
                if let err {
                    fputs("recv error: \(err)\n", stderr); completion(nil); return
                }
                if let d = data, !d.isEmpty { buffer.append(d) }
                // Look for the end of the header block.
                if let hdrEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buffer.subdata(in: 0..<hdrEnd.lowerBound)
                    let bodyStart = hdrEnd.upperBound
                    guard let (line0, headers) = parseHeaders(headerData) else {
                        completion(nil); return
                    }
                    let cl = Int(headers["Content-Length"] ?? "") ?? 0
                    let remainingBody: Int = max(0, cl - (buffer.count - bodyStart))
                    func finish() {
                        let body = cl > 0 ? buffer.subdata(in: bodyStart..<(bodyStart + cl)) : nil
                        let (method, path, query) = parseRequestLine(line0)
                        let remote = remoteIP(conn)
                        completion(HTTPRequest(method: method, path: path,
                                               query: query, headers: headers,
                                               body: body, remoteIP: remote))
                    }
                    if remainingBody == 0 { finish() }
                    else {
                        // Pull the rest of the body.
                        var need = remainingBody
                        func pull() {
                            conn.receive(minimumIncompleteLength: 1, maximumLength: need) { d, _, _, e in
                                if let e { fputs("body err: \(e)\n", stderr); completion(nil); return }
                                if let d, !d.isEmpty { buffer.append(d); need -= d.count }
                                if need <= 0 { finish() } else { pull() }
                            }
                        }
                        pull()
                    }
                } else if isComplete {
                    completion(nil)
                } else {
                    receive()
                }
            }
        }
        receive()
    }

    private static func parseHeaders(_ raw: Data) -> (String, [String: String])? {
        guard let s = String(data: raw, encoding: .utf8) else { return nil }
        var lines = s.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let line0 = lines.removeFirst()
        var headers: [String: String] = [:]
        for l in lines where !l.isEmpty {
            if let colon = l.firstIndex(of: ":") {
                let k = String(l[..<colon])
                let v = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        return (line0, headers)
    }

    private static func parseRequestLine(_ line: String) -> (String, String, [String: String]) {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        let method = parts.count > 0 ? parts[0] : "GET"
        let target = parts.count > 1 ? parts[1] : "/"
        var path = target; var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            let qstr = target[target.index(after: q)...]
            for pair in qstr.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2 {
                    query[String(kv[0]).removingPercentEncoding ?? String(kv[0])] =
                        String(kv[1]).removingPercentEncoding ?? String(kv[1])
                } else if kv.count == 1 {
                    query[String(kv[0])] = ""
                }
            }
        }
        return (method, path, query)
    }

    private static func remoteIP(_ conn: NWConnection) -> String? {
        if case let .hostPort(host, _) = conn.endpoint {
            return "\(host)"
        }
        return nil
    }

    private static func write(conn: NWConnection, resp: HTTPResponse, done: @escaping () -> Void) {
        switch resp.body {
        case .file(let url):
            writeFileBody(conn: conn, resp: resp, url: url, done: done)
        case .empty, .bytes, .stream:
            writeBufferedBody(conn: conn, resp: resp, done: done)
        }
    }

    /// Single-shot send for small responses (JSON, hex previews, login,
    /// status). Builds headers + body in one buffer and hands it to
    /// NWConnection.send.
    private static func writeBufferedBody(conn: NWConnection, resp: HTTPResponse, done: @escaping () -> Void) {
        var out = "HTTP/1.1 \(resp.status) \(reason(resp.status))\r\n"
        var headers = resp.headers
        var bodyBytes: Data = .init()
        switch resp.body {
        case .empty: break
        case .bytes(let b): bodyBytes = b
        case .stream(let producer):
            producer({ chunk in bodyBytes.append(chunk) }, { /* close */ })
        case .file: break // unreachable
        }
        headers["Content-Length"] = String(bodyBytes.count)
        for (k, v) in headers { out += "\(k): \(v)\r\n" }
        out += "\r\n"
        var data = Data(out.utf8); data.append(bodyBytes)
        conn.send(content: data, completion: .contentProcessed { _ in done() })
    }

    /// Stream a file body in 1 MB chunks so the daemon never holds the
    /// whole payload in memory. Buffering a 100+ MB IPA would jetsam
    /// the daemon. The temp file is removed once the stream completes.
    private static func writeFileBody(conn: NWConnection, resp: HTTPResponse, url: URL, done: @escaping () -> Void) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let fh = try? FileHandle(forReadingFrom: url)
        else {
            // Couldn't open. Fall back to a 500 with body.
            let err = HTTPResponse(status: 500,
                                    headers: ["Content-Type": "text/plain", "Connection": "close"],
                                    body: .bytes(Data("cannot read \(url.lastPathComponent)".utf8)))
            writeBufferedBody(conn: conn, resp: err, done: done)
            try? FileManager.default.removeItem(at: url)
            return
        }

        var head = "HTTP/1.1 \(resp.status) \(reason(resp.status))\r\n"
        var headers = resp.headers
        headers["Content-Length"] = String(size)
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        // Send headers first, then each 1 MB chunk back-to-back. The
        // completion handler chains the next read so we don't queue
        // hundreds of megabytes in NWConnection's send buffer.
        let cleanup = {
            try? fh.close()
            try? FileManager.default.removeItem(at: url)
            done()
        }

        func sendChunk() {
            let chunk = fh.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { cleanup(); return }
            conn.send(content: chunk, completion: .contentProcessed { err in
                if err != nil { cleanup(); return }
                sendChunk()
            })
        }

        conn.send(content: Data(head.utf8), completion: .contentProcessed { err in
            if err != nil { cleanup(); return }
            sendChunk()
        })
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        default:  return ""
        }
    }
}
