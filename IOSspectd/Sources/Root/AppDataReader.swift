// AppDataReader.swift - installed apps + data / bundle containers.
//
// Parses the LaunchServices snapshot at
//   <prefix>/var/mobile/Library/MobileInstallation/LastLaunchServicesMap.plist
// where <prefix> is "" on rootful and "/var/jb" on rootless.

import Foundation

final class AppDataReader {
    static let shared = AppDataReader()

    /// Returns one dictionary per installed app, in the schema the web
    /// UI expects (packageName / label / versionName / dataDir / etc.).
    func installedApps(includeSystem: Bool) -> [[String: Any]] {
        let mapPath = self.lsMapPath
        guard let raw = NSDictionary(contentsOfFile: mapPath) as? [String: Any] else {
            // Plist missing or unreadable. Fall back to filesystem scan
            // so the dashboard isn't a blank page even if the cache is
            // empty.
            return scanFilesystem(includeSystem: includeSystem)
        }

        // LastLaunchServicesMap.plist top-level: { "User": {<bundleId>: {...}},
        // "System": {<bundleId>: {...}}, "Hidden": {...}, ... }.
        // We merge User + System (filtered by `includeSystem`) into one list.
        var out: [[String: Any]] = []
        for (sectionKey, value) in raw {
            guard let section = value as? [String: Any] else { continue }
            let isSystem = sectionKey == "System"
            if isSystem && !includeSystem { continue }
            for (bundleId, entry) in section {
                guard let e = entry as? [String: Any] else { continue }
                out.append(makeEntry(bundleId: bundleId, ls: e, isSystem: isSystem))
            }
        }

        // Stable order: user apps first, then alphabetical.
        out.sort { (a, b) -> Bool in
            let sa = (a["system"] as? Bool ?? false)
            let sb = (b["system"] as? Bool ?? false)
            if sa != sb { return !sa }
            return (a["label"] as? String ?? "").lowercased()
                 < (b["label"] as? String ?? "").lowercased()
        }
        return out
    }

    // MARK: - LaunchServices entry -> web schema

    private func makeEntry(bundleId: String, ls: [String: Any], isSystem: Bool) -> [String: Any] {
        let bundlePath = ls["Path"] as? String ?? ""
        let container  = ls["Container"] as? String ?? ""
        let infoPath   = bundlePath + "/Info.plist"
        let info       = (NSDictionary(contentsOfFile: infoPath) as? [String: Any]) ?? [:]

        let label = (info["CFBundleDisplayName"] as? String)
                 ?? (info["CFBundleName"] as? String)
                 ?? bundleId
        let versionName = info["CFBundleShortVersionString"] as? String ?? ""
        let versionCode = info["CFBundleVersion"] as? String ?? ""
        let minOS       = info["MinimumOSVersion"] as? String ?? ""

        let ctime = (try? FileManager.default.attributesOfItem(atPath: bundlePath)[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let mtime = (try? FileManager.default.attributesOfItem(atPath: bundlePath)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        return [
            "packageName"      : bundleId,
            "label"            : label,
            "versionName"      : versionName,
            "versionCode"      : versionCode,
            "uid"              : isSystem ? 0 : 501,
            "targetSdk"        : minOS,
            "sourceDir"        : bundlePath,
            "dataDir"          : container,
            "nativeLibDir"     : bundlePath + "/Frameworks",
            "debuggable"       : false,
            "system"           : isSystem,
            "permissions"      : extractUsageDescriptions(info: info),
            "firstInstallTime" : Int(ctime * 1000),
            "lastUpdateTime"   : Int(mtime * 1000)
        ]
    }

    /// `Info.plist` privacy-purpose keys (NSCameraUsageDescription, etc.)
    /// double as the on-iOS analog of Android's runtime permissions.
    private func extractUsageDescriptions(info: [String: Any]) -> [String] {
        info.keys.filter { $0.hasSuffix("UsageDescription") }.sorted()
    }

    // MARK: - Fallback: filesystem scan

    /// When LastLaunchServicesMap is missing or empty, walk the install
    /// dirs directly. Covers third-party (`User`) installs plus jailbreak
    /// `/Applications` apps.
    private func scanFilesystem(includeSystem: Bool) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let fm = FileManager.default

        // User apps: /var/containers/Bundle/Application/<UUID>/<Name>.app
        let userBase = bundleBaseUser
        if let userIds = try? fm.contentsOfDirectory(atPath: userBase) {
            for u in userIds {
                let uuidDir = userBase + "/" + u
                guard let appName = (try? fm.contentsOfDirectory(atPath: uuidDir))?.first(where: { $0.hasSuffix(".app") }) else { continue }
                let bundlePath = uuidDir + "/" + appName
                guard let entry = synthesizeEntry(bundlePath: bundlePath, isSystem: false) else { continue }
                out.append(entry)
            }
        }

        if includeSystem {
            // Jailbreak side-loaded apps under /Applications or /var/jb/Applications
            for sysBase in [bundleBaseSystem, "/Applications"] {
                if let ids = try? fm.contentsOfDirectory(atPath: sysBase) {
                    for d in ids where d.hasSuffix(".app") {
                        let bundlePath = sysBase + "/" + d
                        guard let entry = synthesizeEntry(bundlePath: bundlePath, isSystem: true) else { continue }
                        out.append(entry)
                    }
                }
            }
        }

        out.sort { ($0["label"] as? String ?? "").lowercased() < ($1["label"] as? String ?? "").lowercased() }
        return out
    }

    private func synthesizeEntry(bundlePath: String, isSystem: Bool) -> [String: Any]? {
        let info = (NSDictionary(contentsOfFile: bundlePath + "/Info.plist") as? [String: Any]) ?? [:]
        guard let bundleId = info["CFBundleIdentifier"] as? String else { return nil }
        // Best-effort data container lookup by walking
        // /var/mobile/Containers/Data/Application/<UUID>/.com.apple.mobile_container_manager.metadata.plist
        let container = findDataContainer(for: bundleId) ?? ""
        return makeEntry(
            bundleId: bundleId,
            ls: ["Path": bundlePath, "Container": container],
            isSystem: isSystem
        )
    }

    private func findDataContainer(for bundleId: String) -> String? {
        let fm = FileManager.default
        let base = containerBase
        guard let uuids = try? fm.contentsOfDirectory(atPath: base) else { return nil }
        for u in uuids {
            let meta = base + "/" + u + "/.com.apple.mobile_container_manager.metadata.plist"
            if let d = NSDictionary(contentsOfFile: meta) as? [String: Any],
               (d["MCMMetadataIdentifier"] as? String) == bundleId {
                return base + "/" + u
            }
        }
        return nil
    }

    // MARK: - Path resolution
    //
    // iOS system dirs live at the OS root regardless of jailbreak type:
    //   /var/mobile/...          (data containers, LaunchServices cache)
    //   /var/containers/Bundle/  (user app bundles)
    // Only jailbreak-managed files are under /var/jb on rootless. The
    // daemon has no-sandbox + platform-application entitlements so it
    // can read these absolute paths whether we're root or mobile.
    //
    // Jailbreak app installs (Sileo .deb apps) DO move:
    //   rootful  -> /Applications/<Name>.app
    //   rootless -> /var/jb/Applications/<Name>.app
    private var jbPrefix: String {
        FileManager.default.fileExists(atPath: "/var/jb") ? "/var/jb" : ""
    }
    private var lsMapPath: String {
        "/var/mobile/Library/MobileInstallation/LastLaunchServicesMap.plist"
    }
    private var bundleBaseUser: String {
        "/var/containers/Bundle/Application"
    }
    private var bundleBaseSystem: String {
        jbPrefix + "/Applications"
    }
    private var containerBase: String {
        "/var/mobile/Containers/Data/Application"
    }
}
