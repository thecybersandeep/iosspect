// CryptoUtil.swift - password + IP discovery helpers. The on-disk
// password is 6 chars of A-Z + 0-9 for usability (typing it from a
// phone screen into a browser). Auth is rate-limited so the entropy is
// sufficient.

import Foundation
import Security
import Darwin

enum CryptoUtil {

    static func randomPassword(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var out = ""
        for _ in 0..<length {
            var b: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &b)
            out.append(alphabet[Int(b) % alphabet.count])
        }
        return out
    }
}

// Tiny IP discovery used by ServerControl. Lives here so the dashboard
// keeps importing one file.
enum NetworkUtil {
    /// First non-loopback IPv4 of the active interface. nil on cellular-
    /// only with VPN off.
    static func primaryIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while ptr != nil {
            let i = ptr!.pointee
            let family = i.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: i.ifa_name)
                if name == "en0" || name == "en1" || name == "pdp_ip0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(i.ifa_addr,
                                   socklen_t(i.ifa_addr.pointee.sa_len),
                                   &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let s = String(cString: host)
                        if !s.hasPrefix("127.") { return s }
                    }
                }
            }
            ptr = i.ifa_next
        }
        return nil
    }
}
