// Settings.swift - runtime settings shared between the SwiftUI app and
// the daemon. Backed by a plist at
// /var/mobile/Library/IOSspect/settings.plist so root daemon and mobile
// app see the same values.

import Foundation

final class Settings {

    static let shared = Settings()

    private let defaults: UserDefaults
    private let groupPath: String

    /// Browser password length. The short 6-char form is convenient on
    /// a phone screen; the persistent global rate limiter in
    /// Security.swift carries most of the brute-force defence (20
    /// failures across all source IPs in 10 minutes locks login for
    /// 10 minutes, surviving daemon restart). Don't drop below 6.
    static let minPasswordLength = 6

    private init() {
        // We can't use App Groups on jailbroken iOS reliably, so we own
        // our own plist on disk. The daemon reads the same file.
        let base = "/var/mobile/Library/IOSspect"
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        self.groupPath = "\(base)/settings.plist"
        // Lift values from the on-disk plist into a per-process UserDefaults
        // suite for fast reads. Writes always go through write().
        self.defaults = UserDefaults(suiteName: "com.iosspect.shared") ?? .standard
        if let dict = NSDictionary(contentsOfFile: groupPath) as? [String: Any] {
            for (k, v) in dict { defaults.set(v, forKey: k) }
        }
        // Migrate empty / sub-minimum passwords on first launch so the
        // daemon never refuses to start because of a malformed plist.
        if let p = defaults.string(forKey: "password"), p.count < Self.minPasswordLength {
            _ = regeneratePassword()
        }
    }

    // MARK: - Port

    var port: Int {
        get { defaults.integer(forKey: "port").nonZero ?? 8008 }
        set { defaults.set(newValue, forKey: "port"); persist() }
    }

    // MARK: - Browser password

    var password: String {
        get {
            if let p = defaults.string(forKey: "password"), !p.isEmpty { return p }
            return regeneratePassword()
        }
    }

    @discardableResult
    func regeneratePassword() -> String {
        let p = CryptoUtil.randomPassword(length: Self.minPasswordLength)
        defaults.set(p, forKey: "password"); persist()
        return p
    }

    // MARK: - LAN listen toggle
    //
    // Default is `false` for fresh installs: the daemon binds 127.0.0.1
    // only and is reachable solely from on-device clients (or via an
    // `ssh -L 8008:127.0.0.1:8008` tunnel). The user can flip this in
    // the dashboard to expose the daemon on the LAN.
    //
    // For migration treat an existing settings.plist (any value other
    // than nil/false) as the user having explicitly chosen LAN access,
    // so an in-use deployment is not broken on first daemon-upgrade.

    var bindLocalOnly: Bool {
        get {
            if defaults.object(forKey: "bindLocalOnlySet") == nil {
                // Pre-hardening installs that already had a working LAN
                // setup keep LAN access; brand-new installs default to
                // local-only.
                return defaults.string(forKey: "password") == nil
            }
            return defaults.bool(forKey: "bindLocalOnly")
        }
        set {
            defaults.set(newValue, forKey: "bindLocalOnly")
            defaults.set(true, forKey: "bindLocalOnlySet")
            persist()
        }
    }

    // MARK: - Persist to shared plist

    private func persist() {
        let dict = defaults.dictionaryRepresentation()
        // Only persist our own keys, not the entire defaults universe.
        let ours = ["port", "password", "bindLocalOnly", "bindLocalOnlySet"]
        let filtered = NSMutableDictionary()
        for k in ours {
            if let v = dict[k] { filtered.setValue(v, forKey: k) }
        }
        filtered.write(toFile: groupPath, atomically: true)
        // Make the file world-readable so the daemon (root) and the app
        // (mobile uid) both pick it up.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: groupPath)
    }
}

private extension Int {
    /// Returns nil for the legacy `integer(forKey:)` default of 0.
    var nonZero: Int? { self == 0 ? nil : self }
}
