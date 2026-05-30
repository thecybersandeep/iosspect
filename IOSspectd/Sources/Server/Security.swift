// Security.swift - auth, rate-limiter, session cookie.
//
//   - Password compare in constant time.
//   - Per-IP exponential backoff (RateLimiter.perIP).
//   - Persistent global failure counter so a daemon crash / restart
//     cannot wipe the lockout (RateLimiter.global).
//   - Constant-time JSON parse-or-empty for the login payload so an
//     empty / malformed body does not consume the rate-limit budget.
//   - 6-character minimum on the configured password. The iOS app
//     auto-regenerates anything shorter at first launch.
//   - Session tokens are 24 random bytes from SecRandomCopyBytes.
//   - Sessions persist to /var/mobile/Library/IOSspect/sessions.json
//     (mode 0600) so a Restart does not log the user out.
//   - POST /api/auth/logout invalidates the cookie server-side.
//
// All routes other than the asset bundle (`/`, `/index.html`, `/app.js`,
// `/app.css`, `/icon.svg`) and the auth endpoints require a valid cookie.

import Foundation
import CryptoKit

final class SecurityManager {

    private let password: String
    private let rate: RateLimiter
    private let sessions: SessionStore

    init(password: String) {
        self.password = password
        self.rate = RateLimiter()
        self.sessions = SessionStore()
    }

    // MARK: - Login

    /// Returns (httpStatus, body, optionalSetCookieValue).
    func login(ip: String, password attempt: String) -> (Int, [String: Any], String?) {
        // Refuse empty attempts without touching the rate limiter so a
        // typo cannot be exploited as a free probe.
        if attempt.isEmpty {
            return (400, ["error": "password required"], nil)
        }
        // Global lock takes precedence so an attacker rotating source
        // IPs cannot reset the limiter by hitting fresh addresses.
        let globalMs = rate.globalLockoutRemainingMs()
        if globalMs > 0 {
            return (429, ["error": "too many attempts, try again in \(globalMs / 1000 + 1)s"], nil)
        }
        let perIpMs = rate.perIPLockoutRemainingMs(ip: ip)
        if perIpMs > 0 {
            return (429, ["error": "too many attempts, try again in \(perIpMs / 1000 + 1)s"], nil)
        }
        guard constantTimeEquals(attempt, password) else {
            rate.onFailure(ip)
            return (401, ["error": "wrong password"], nil)
        }
        rate.onSuccess(ip)
        let token = sessions.create()
        let cookie = "\(Self.cookieName)=\(token); Max-Age=43200; Path=/; Secure; HttpOnly; SameSite=Strict"
        return (200, ["ok": true], cookie)
    }

    func logout(cookieHeader: String?) -> String? {
        if let token = readCookie(cookieHeader, name: Self.cookieName) {
            sessions.invalidate(token: token)
        }
        // Max-Age=0 + empty value evicts the browser-side cookie even
        // if the token wasn't recognised.
        return "\(Self.cookieName)=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Strict"
    }

    // MARK: - Per-request check

    /// True if the session cookie corresponds to a still-valid session.
    func authorize(cookieHeader: String?) -> Bool {
        guard let token = readCookie(cookieHeader, name: Self.cookieName) else { return false }
        return sessions.touch(token: token)
    }

    // MARK: - Crypto

    /// Length-independent constant time compare. Padding to 256 bytes
    /// means the comparison time leaks nothing about the password's
    /// actual length.
    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let max = 256
        let ad = Array(a.utf8.prefix(max)) + [UInt8](repeating: 0, count: max)
        let bd = Array(b.utf8.prefix(max)) + [UInt8](repeating: 0, count: max)
        var diff: UInt8 = a.utf8.count == b.utf8.count ? 0 : 1
        for i in 0..<max { diff |= ad[i] ^ bd[i] }
        return diff == 0
    }

    static let cookieName = "iosspect_sid"

    private func readCookie(_ header: String?, name: String) -> String? {
        guard let header else { return nil }
        for raw in header.split(separator: ";") {
            let kv = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            if kv.count == 2 {
                let k = kv[0].trimmingCharacters(in: .whitespaces)
                if k == name { return String(kv[1]) }
            }
        }
        return nil
    }
}

// MARK: - Rate limiter
//
// Two counters:
//   perIP  : exponential backoff per source address. Defeats sequential
//            brute force.
//   global : single counter incremented on every failure regardless of
//            source. After N failures in a sliding window all login
//            attempts are locked. Defeats IP-rotation attacks.
//
// Both counters persist to /var/mobile/Library/IOSspect/ratelimit.json
// so a daemon crash or restart cannot reset the lockout. A malicious
// LAN scanner cannot ride the launchd KeepAlive bounce to wipe failure
// history.

private final class RateLimiter {

    private struct PerIP: Codable {
        var failures: Int
        var nextAllowedAtMs: Int64
    }
    private struct Global: Codable {
        /// Total failures since the start of the current window.
        var failures: Int
        /// Window start (unix ms).
        var windowStartMs: Int64
        /// Lockout-until (unix ms). 0 means not locked.
        var lockoutUntilMs: Int64
    }
    private struct Snapshot: Codable {
        var perIP: [String: PerIP]
        var global: Global
    }

    private var perIP: [String: PerIP] = [:]
    private var global = Global(failures: 0, windowStartMs: 0, lockoutUntilMs: 0)
    private let lock = NSLock()

    // Per-IP knobs.
    private let baseBackoffMs: Int64 = 1000
    private let maxBackoffMs: Int64 = 60_000

    // Global knobs. 20 failures inside a 10-minute window triggers a
    // 10-minute global lockout. Tunable; chosen so a legitimate user
    // mistyping a few times stays under the limit but a scanner does
    // not.
    private let globalWindowMs: Int64 = 10 * 60 * 1000
    private let globalThreshold = 20
    private let globalLockoutMs: Int64 = 10 * 60 * 1000

    private let path = "/var/mobile/Library/IOSspect/ratelimit.json"

    init() { load() }

    func onFailure(_ ip: String) {
        lock.lock(); defer { lock.unlock() }
        // Per-IP.
        var s = perIP[ip] ?? PerIP(failures: 0, nextAllowedAtMs: 0)
        s.failures += 1
        let backoff = min(baseBackoffMs << min(s.failures - 1, 6), maxBackoffMs)
        s.nextAllowedAtMs = Self.nowMs() + backoff
        perIP[ip] = s

        // Global.
        let now = Self.nowMs()
        if now - global.windowStartMs > globalWindowMs {
            global.windowStartMs = now
            global.failures = 0
        }
        global.failures += 1
        if global.failures >= globalThreshold {
            global.lockoutUntilMs = now + globalLockoutMs
        }
        save()
    }

    func onSuccess(_ ip: String) {
        lock.lock(); defer { lock.unlock() }
        perIP.removeValue(forKey: ip)
        // Reset the global window too: a correct password is proof
        // this isn't a brute-force.
        global = Global(failures: 0, windowStartMs: 0, lockoutUntilMs: 0)
        save()
    }

    func perIPLockoutRemainingMs(ip: String) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let s = perIP[ip] else { return 0 }
        return max(0, s.nextAllowedAtMs - Self.nowMs())
    }

    func globalLockoutRemainingMs() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return max(0, global.lockoutUntilMs - Self.nowMs())
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        perIP = s.perIP
        global = s.global
    }

    private func save() {
        let snap = Snapshot(perIP: perIP, global: global)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                ofItemAtPath: path)
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - Sessions

private final class SessionStore {

    private struct Entry: Codable { var lastSeen: TimeInterval }
    private var live: [String: Entry] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval = 12 * 60 * 60 // 12 hours
    private let path = "/var/mobile/Library/IOSspect/sessions.json"

    init() { load() }

    func create() -> String {
        let token = newToken()
        lock.lock()
        live[token] = Entry(lastSeen: Date().timeIntervalSince1970)
        let snap = live
        lock.unlock()
        save(snap)
        return token
    }

    func touch(token: String) -> Bool {
        lock.lock()
        guard var e = live[token] else { lock.unlock(); return false }
        let now = Date().timeIntervalSince1970
        if now - e.lastSeen > ttl {
            live.removeValue(forKey: token)
            let snap = live
            lock.unlock()
            save(snap)
            return false
        }
        e.lastSeen = now
        live[token] = e
        let snap = live
        lock.unlock()
        save(snap)
        return true
    }

    func invalidate(token: String) {
        lock.lock()
        live.removeValue(forKey: token)
        let snap = live
        lock.unlock()
        save(snap)
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        let cutoff = Date().timeIntervalSince1970 - ttl
        live = decoded.filter { $0.value.lastSeen >= cutoff }
    }

    private func save(_ snap: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                ofItemAtPath: path)
    }

    private func newToken() -> String {
        var b = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Data(b).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Public auth routes

func authRoutes(router: Router, security: SecurityManager) {
    router.post("/api/auth/login") { req, ctx in
        // Defense-in-depth: only accept JSON-typed bodies. A cross-origin
        // text/plain form post cannot slip through if SameSite is ever
        // loosened.
        let ct = req.headers["Content-Type"] ?? ""
        guard ct.lowercased().hasPrefix("application/json") else {
            return ctx.json(["error": "expected JSON body"], status: 415)
        }
        let body = (try? JSONSerialization.jsonObject(with: req.body ?? Data())) as? [String: Any]
        // Trim leading/trailing whitespace: from a hand-typed password
        // it is almost always a mistake.
        let raw = (body?["password"] as? String) ?? ""
        let password = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = req.remoteIP ?? "?"
        let (status, payload, cookie) = security.login(ip: ip, password: password)
        var resp = ctx.json(payload, status: status)
        if let cookie { resp.headers["Set-Cookie"] = cookie }
        return resp
    }

    router.post("/api/auth/logout") { req, ctx in
        var resp = ctx.json(["ok": true])
        if let cookie = security.logout(cookieHeader: req.headers["Cookie"]) {
            resp.headers["Set-Cookie"] = cookie
        }
        return resp
    }
}
