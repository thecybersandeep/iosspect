// IOSspectServer.swift - HTTP/HTTPS server for the IOSspect daemon.
//
// Built on Foundation + Network.framework rather than Hummingbird or
// Vapor: swift-nio + SwiftPM resolution under Theos is fragile on
// jailbroken iOS. The server speaks HTTP/1.1 + HTTPS via TLS options
// configured through Network.framework.

import Foundation
import Network

final class IOSspectServer {

    private let listener: NWListener
    let port: Int
    let tls: TLSManager.State
    let router = Router()
    let security: SecurityManager

    init() throws {
        // Load runtime settings written by the SwiftUI app.
        let cfg = SharedSettings.load()
        // Refuse to bind with the legacy CHANGEME default or an empty /
        // sub-6-char password. The iOS app's Settings init already
        // auto-rotates anything below the minimum, so a short value
        // here means the plist was hand-edited.
        guard cfg.password.count >= 6, cfg.password != "CHANGEME" else {
            fputs("FATAL: password must be at least 6 characters; refusing to bind\n", stderr)
            throw NSError(domain: "IOSspect", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "password too weak (need 6+ chars)"])
        }
        self.port = cfg.port
        self.tls  = try TLSManager.getOrCreate()
        self.security = SecurityManager(password: cfg.password)

        try? tls.writeFingerprint()

        let params = try NWParameters(tls: tls.makeNWTLSOptions())
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        // Default to 127.0.0.1-only for fresh installs. The iOS app
        // surfaces a toggle so the user can opt into LAN access.
        params.acceptLocalOnly = cfg.bindLocalOnly
        self.listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port)))

        installRoutes()
    }

    private(set) var isListening: Bool = false

    func start() throws {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            HTTPConnection.handle(conn,
                                  router: self.router,
                                  security: self.security,
                                  webRoot: WebAssets.path)
        }
        listener.start(queue: .global(qos: .userInitiated))
        isListening = true
        let bind = SharedSettings.load().bindLocalOnly ? "127.0.0.1" : "0.0.0.0"
        fputs("listening on https://\(bind):\(port)  fingerprint \(tls.fingerprintShort)\n", stdout)
    }

    /// Cancel the NWListener so the daemon stops accepting connections.
    /// The daemon process stays alive (launchd KeepAlive=true) so the
    /// control timer can still react to a later "start" command.
    func stop() {
        listener.cancel()
        isListening = false
        fputs("listener cancelled on port \(port)\n", stdout)
    }

    private func installRoutes() {
        // Order: auth routes first (they pre-empt session checks),
        // then asset (the SPA), then everything else. The router runs
        // them in registration order.
        authRoutes(router: router, security: security)
        systemRoutes(router: router)
        appRoutes(router: router)
        fileRoutes(router: router)
        prefsRoutes(router: router)
        sqliteRoutes(router: router)
        manifestRoutes(router: router)
        liveRoutes(router: router)
        assetRoutes(router: router)
    }
}

// MARK: - WebAssets

/// Where the daemon finds the bundled SPA. Theos copies the layout/
/// tree onto the device, so the SPA lives at /usr/share/iosspect/web/
/// after dpkg -i (see DEBIAN/postinst).
enum WebAssets {
    static var path: String {
        let candidates = [
            "/var/jb/usr/share/iosspect/web",
            "/usr/share/iosspect/web",
            (Bundle.main.resourcePath ?? "") + "/web"
        ]
        for c in candidates {
            var d: ObjCBool = false
            if FileManager.default.fileExists(atPath: c, isDirectory: &d), d.boolValue {
                return c
            }
        }
        return "/usr/share/iosspect/web"
    }
}

// MARK: - Shared settings on disk

struct SharedSettings {
    let port: Int
    let password: String
    /// True = bind 127.0.0.1 only (default for new installs).
    /// False = listen on 0.0.0.0 (user opted in via the iOS app).
    let bindLocalOnly: Bool
    static func load() -> SharedSettings {
        let p = "/var/mobile/Library/IOSspect/settings.plist"
        let dict = NSDictionary(contentsOfFile: p) as? [String: Any] ?? [:]
        let port = (dict["port"] as? Int) ?? 8008
        // Empty means refuse to start. The daemon enforces a 6-char
        // minimum at bind time.
        let password = (dict["password"] as? String) ?? ""
        // Match Settings.bindLocalOnly migration logic: if the explicit
        // flag was never written, infer from whether the user already
        // had a settings.plist with a password.
        let explicitlySet = (dict["bindLocalOnlySet"] as? Bool) ?? false
        let bindLocalOnly: Bool
        if explicitlySet {
            bindLocalOnly = (dict["bindLocalOnly"] as? Bool) ?? true
        } else {
            // Existing deployment with a password but no toggle yet:
            // preserve current LAN behaviour. Fresh install: local-only.
            bindLocalOnly = password.isEmpty
        }
        return .init(port: port, password: password, bindLocalOnly: bindLocalOnly)
    }
}
