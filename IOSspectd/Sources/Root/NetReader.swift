// NetReader.swift - TCP + UDP socket tables on iOS.
//
// sysctl(net.inet.tcp.pcblist) + a binary decoder for xinpcb_n / xtcpcb_n
// would be ~300 lines of layout code that shifts between iOS versions.
// Shell out to `netstat -anv` from network-cmds instead. UID is not in
// the netstat output and is reported as 0; per-app filtering isn't
// available until the sysctl path lands.

import Foundation
import Darwin

enum NetReader {

    struct Conn: Codable {
        let proto: String       // tcp, tcp6, udp, udp6
        let localAddr: String   // ip:port
        let remoteAddr: String
        let state: String       // ESTABLISHED, LISTEN, "" for UDP
        let uid: UInt32         // 0, see header
        let inode: UInt64       // unused on iOS, kept for parity
    }

    static func list() -> [Conn] {
        var all: [Conn] = []
        if let tcp = run("-p", "tcp") { all.append(contentsOf: parse(tcp, isTCP: true)) }
        if let udp = run("-p", "udp") { all.append(contentsOf: parse(udp, isTCP: false)) }
        return all
    }

    // MARK: - netstat exec

    private static func run(_ args: String...) -> String? {
        let candidates = ["/var/jb/usr/sbin/netstat",
                          "/usr/sbin/netstat",
                          "/var/jb/bin/netstat",
                          "/bin/netstat"]
        guard let netstat = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            fputs("NetReader: netstat not found\n", stderr)
            return nil
        }
        let cmd = ([netstat, "-an"] + args).joined(separator: " ")
        let r = ShellRunner.sh(cmd, timeoutSec: 3)
        if r.code != 0 && r.stdout.isEmpty {
            fputs("NetReader: netstat exit=\(r.code) err=\(r.stderr)\n", stderr)
            return nil
        }
        return r.stdout
    }

    // MARK: - Parse

    /// netstat -an -p tcp output (Darwin):
    ///   Active Internet connections (including servers)
    ///   Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
    ///   tcp4       0      0  127.0.0.1.27042        *.*                    LISTEN
    ///   tcp6       0      0  ::1.8008               *.*                    LISTEN
    /// For UDP the state column is just absent.
    private static func parse(_ text: String, isTCP: Bool) -> [Conn] {
        var out: [Conn] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            // Skip headers / blanks.
            if s.isEmpty || s.hasPrefix("Active ") || s.hasPrefix("Proto ") { continue }
            let parts = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Need at least: proto recv send local foreign [state]
            guard parts.count >= 5 else { continue }
            let proto = parts[0]
            // Filter to the protocol family we asked for.
            if isTCP && !proto.hasPrefix("tcp") { continue }
            if !isTCP && !proto.hasPrefix("udp") { continue }
            let local = normalizeAddr(parts[3])
            let remote = normalizeAddr(parts[4])
            let state = (isTCP && parts.count >= 6) ? parts[5] : ""
            out.append(.init(proto: proto, localAddr: local,
                             remoteAddr: remote, state: state,
                             uid: 0, inode: 0))
        }
        return out
    }

    /// Darwin netstat uses dot-separated port: "127.0.0.1.8008" and
    /// "::1.8008". Convert to "127.0.0.1:8008" / "[::1]:8008" for a
    /// familiar shape.
    private static func normalizeAddr(_ s: String) -> String {
        guard let dot = s.lastIndex(of: ".") else { return s }
        let host = String(s[..<dot])
        let port = String(s[s.index(after: dot)...])
        if host == "*" { return "*:\(port)" }
        if host.contains(":") { return "[\(host)]:\(port)" }  // IPv6
        return "\(host):\(port)"
    }
}
