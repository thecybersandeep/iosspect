// OSVersion.swift - iOS version probe for the daemon (UIDevice is not
// available in this CLI binary).
//
// Three live OS branches in the fleet:
//   - iOS 15.x         old SwiftUI surface, /var/jb may not exist
//   - iOS 16.7.x LTS   A11 devices stuck on 16
//   - iOS 26.x         current Apple release; new jailbreak prefix
//                      scheme, slightly different log stream output
//
// Code that needs to branch on the running OS reads OSVersion.major /
// .minor instead of doing string parsing inline.

import Foundation

enum OSVersion {

    static let current: (major: Int, minor: Int, patch: Int) = parse()

    static var major: Int { current.major }
    static var minor: Int { current.minor }
    static var patch: Int { current.patch }

    static var isIOS15: Bool { current.major == 15 }
    static var isIOS16: Bool { current.major == 16 }
    static var isIOS17: Bool { current.major == 17 }
    static var isIOS18OrLater: Bool { current.major >= 18 }
    static var isIOS26OrLater: Bool { current.major >= 26 }

    /// True on Apple's long-term-support 16.7.x branch for older
    /// devices (iPhone 8 / X). Informational; the API surface matches
    /// 16.6 in every way that matters here.
    static var isLTS_16_7: Bool { current.major == 16 && current.minor == 7 }

    static var raw: String {
        "\(current.major).\(current.minor).\(current.patch)"
    }

    // MARK: - Parse

    private static func parse() -> (Int, Int, Int) {
        // SystemVersion.plist is the single source of truth on every
        // iOS release. The kern.osproductversion sysctl reports the
        // same string on iOS 16+ but is missing on some earlier 15.x
        // builds; we prefer the plist.
        let plist = NSDictionary(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist")
        let v = (plist?["ProductVersion"] as? String) ?? sysctlVersion() ?? "0.0.0"
        let parts = v.split(separator: ".").map { Int($0) ?? 0 }
        let major = parts.count > 0 ? parts[0] : 0
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        return (major, minor, patch)
    }

    private static func sysctlVersion() -> String? {
        var size = 0
        sysctlbyname("kern.osproductversion", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osproductversion", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
}

// MARK: - Jailbreak prefix probe

/// Resolves the on-disk prefix the active jailbreak uses for its
/// installed files. This matters for /Library/LaunchDaemons paths,
/// /usr/local/bin tool paths, and /usr/bin/openssl.
///
///   - rootful           Old-style "/" prefix (palera1n rootful, XinaA15)
///   - "/var/jb"         Modern rootless (Dopamine, palera1n rootless)
///   - "/var/jb/<rand>"  palera1n "roothide" mode with randomised prefix
enum JailbreakPrefix {
    static let path: String = resolve()

    private static func resolve() -> String {
        let fm = FileManager.default
        // roothide: random folder under /var, look for our own
        // LaunchDaemons plist in any depth-2 child.
        if let contents = try? fm.contentsOfDirectory(atPath: "/var") {
            for entry in contents where entry.count >= 8 {
                let candidate = "/var/\(entry)"
                if fm.fileExists(atPath: "\(candidate)/Library/LaunchDaemons/com.iosspect.daemon.plist") {
                    return candidate
                }
            }
        }
        // Standard rootless
        if fm.fileExists(atPath: "/var/jb/Library/LaunchDaemons/com.iosspect.daemon.plist") {
            return "/var/jb"
        }
        // Rootful
        return ""
    }
}
