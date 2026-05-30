// TLSManager.swift - self-signed cert + private key for the daemon.
//
// On first launch generate a P-256 keypair, build a self-signed X.509
// with SAN entries for localhost + 127.0.0.1 + the device's LAN IPv4,
// write it to disk as a PKCS#12, and expose its SHA-256 fingerprint so
// the user can verify their browser sees the same one.
//
// Subsequent launches reuse the on-disk PKCS#12 unless the device's IP
// changes, in which case it is re-issued.

import Foundation
import Security
import Network
import CryptoKit
import Darwin

enum TLSManager {

    struct State {
        let pkcs12Data: Data
        let pkcs12Password: String
        let fingerprintFull: String     // "AA:BB:CC:..." 32 bytes hex
        let fingerprintShort: String    // first 8 bytes
        let sans: [String]

        func makeNWTLSOptions() throws -> NWProtocolTLS.Options {
            let opts = NWProtocolTLS.Options()
            // Network.framework wants a SecIdentity. Extract it from our
            // PKCS#12 with SecPKCS12Import.
            let pwd = pkcs12Password as CFString
            let importOpts: NSDictionary = [kSecImportExportPassphrase: pwd]
            var items: CFArray?
            let status = SecPKCS12Import(pkcs12Data as CFData, importOpts, &items)
            guard status == errSecSuccess, let arr = items as? [[String: Any]],
                  let first = arr.first,
                  let identity = first[kSecImportItemIdentity as String]
            else { throw NSError(domain: "TLSManager", code: Int(status)) }
            // swiftlint:disable force_cast
            let secIdentity = identity as! SecIdentity
            // swiftlint:enable force_cast
            let secOptions = opts.securityProtocolOptions
            sec_protocol_options_set_local_identity(
                secOptions,
                sec_identity_create(secIdentity)!
            )
            sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv12)
            return opts
        }

        func writeFingerprint() throws {
            try FileManager.default.createDirectory(
                atPath: CertPaths.dir, withIntermediateDirectories: true
            )
            try fingerprintShort.write(
                toFile: CertPaths.fingerprintFile,
                atomically: true, encoding: .utf8
            )
        }
    }

    static func getOrCreate() throws -> State {
        let p12Path = CertPaths.dir + "/keystore.p12"
        let pwd = "iosspect"
        let currentIP = NetworkUtilDaemon.primaryIPv4() ?? "127.0.0.1"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: p12Path)) {
            // Try to reuse the existing p12 only if its SAN still matches
            // the device's current primary IPv4. If the phone joined a new
            // WiFi network the SAN is stale and Chrome rejects new TLS
            // connections (`recv error: -9825: misc. bad certificate`),
            // which makes downloads fail mysteriously.
            if certCoversIP(p12Path: p12Path, password: pwd, ip: currentIP) {
                do {
                    return try state(from: data, password: pwd)
                } catch {
                    try? FileManager.default.removeItem(atPath: p12Path)
                }
            } else {
                fputs("TLS: cert SAN does not cover \(currentIP), regenerating\n", stdout)
                try? FileManager.default.removeItem(atPath: p12Path)
            }
        }
        // First-run generation. Shell out to /usr/bin/openssl which
        // ships on every jailbroken iOS via the procursus toolchain.
        try? FileManager.default.createDirectory(atPath: CertPaths.dir, withIntermediateDirectories: true)
        let ip = NetworkUtilDaemon.primaryIPv4() ?? "127.0.0.1"
        let san = """
        DNS.1 = localhost
        IP.1  = 127.0.0.1
        IP.2  = \(ip)
        """
        let cnf = CertPaths.dir + "/req.cnf"
        let pem = CertPaths.dir + "/cert.pem"
        let key = CertPaths.dir + "/key.pem"
        // `distinguished_name=req_distinguished_name` points at the
        // [req_distinguished_name] section. Pointing it at [req] makes
        // openssl re-parse the [req] section as DN entries and crash
        // with "invalid field name".
        let cnfBody = """
        [req]
        distinguished_name = req_distinguished_name
        x509_extensions = v3_ext
        prompt = no
        [req_distinguished_name]
        CN = IOSspect on \(UIDeviceShim.name())
        [v3_ext]
        subjectAltName = @san
        keyUsage = digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        [san]
        \(san)
        """
        try cnfBody.write(toFile: cnf, atomically: true, encoding: .utf8)
        // openssl is at /var/jb/usr/bin/openssl on rootless, /usr/bin/openssl
        // on rootful. Try both.
        let openssl = ["/var/jb/usr/bin/openssl", "/usr/bin/openssl"]
            .first { FileManager.default.fileExists(atPath: $0) }
            ?? "/usr/bin/openssl"
        try shell(openssl, [
            "req", "-x509", "-newkey", "ec",
            "-pkeyopt", "ec_paramgen_curve:P-256",
            "-keyout", key, "-out", pem,
            "-days", "3650", "-nodes",
            "-config", cnf
        ])
        try shell(openssl, [
            "pkcs12", "-export",
            // -legacy uses the older RC2/3DES encryption that iOS's
            // Security.framework accepts. Without it, modern openssl
            // (3.x+) defaults to AES-256-CBC + PBKDF2 which SecPKCS12Import
            // rejects with errSecAuthFailed (-25293).
            "-legacy",
            "-inkey", key, "-in", pem,
            "-out", p12Path,
            "-passout", "pass:\(pwd)",
            "-name", "iosspect"
        ])
        // Explicitly lock the keystore to 0600 root:wheel. The
        // umask(0o077) at daemon boot already does this, but being
        // explicit guards against a future umask relax leaking the
        // TLS key on disk.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                ofItemAtPath: p12Path)
        // Clean up the loose PEM + key. Only the p12 needs to survive.
        try? FileManager.default.removeItem(atPath: cnf)
        try? FileManager.default.removeItem(atPath: pem)
        try? FileManager.default.removeItem(atPath: key)
        return try state(from: Data(contentsOf: URL(fileURLWithPath: p12Path)),
                         password: pwd)
    }

    // MARK: - Helpers

    private static func state(from data: Data, password: String) throws -> State {
        // Fingerprint the leaf cert inside the PKCS#12. We re-import to
        // get the SecCertificate object.
        let importOpts: NSDictionary = [kSecImportExportPassphrase: password as CFString]
        var items: CFArray?
        let st = SecPKCS12Import(data as CFData, importOpts, &items)
        guard st == errSecSuccess, let arr = items as? [[String: Any]], let first = arr.first
        else { throw NSError(domain: "TLSManager", code: Int(st)) }
        // swiftlint:disable force_cast
        let identity = first[kSecImportItemIdentity as String] as! SecIdentity
        // swiftlint:enable force_cast
        var leaf: SecCertificate?
        SecIdentityCopyCertificate(identity, &leaf)
        guard let cert = leaf else { throw NSError(domain: "TLSManager", code: -1) }
        let der = SecCertificateCopyData(cert) as Data
        let digest = SHA256.hash(data: der)
        let full = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
        let short = full.split(separator: ":").prefix(8).joined(separator: ":")
        return State(pkcs12Data: data,
                     pkcs12Password: password,
                     fingerprintFull: full,
                     fingerprintShort: String(short),
                     sans: ["localhost", "127.0.0.1"])
    }

    /// True iff the .p12 at `p12Path` contains a leaf cert whose
    /// subjectAltName covers `ip`. Returns false on any decode failure
    /// so the caller regenerates from scratch.
    ///
    /// iOS Security.framework doesn't expose SecCertificateCopyValues /
    /// kSecOIDSubjectAltName (those are macOS-only), so we shell to
    /// openssl which the daemon already depends on for cert generation.
    private static func certCoversIP(p12Path: String, password: String, ip: String) -> Bool {
        let openssl = ["/var/jb/usr/bin/openssl", "/usr/bin/openssl"]
            .first { FileManager.default.fileExists(atPath: $0) }
            ?? "/usr/bin/openssl"
        // openssl pkcs12 -in <p12> -nokeys -legacy -password pass:<pwd>
        //   | openssl x509 -noout -text
        // Parse the resulting text for "IP Address:<ip>" lines under the
        // X509v3 SubjectAlternativeName extension.
        let cmd = "\(openssl) pkcs12 -in \(p12Path) -nokeys -legacy -password pass:\(password) 2>/dev/null"
                + " | \(openssl) x509 -noout -text 2>/dev/null"
        let r = ShellRunner.sh(cmd, timeoutSec: 5)
        guard r.code == 0 else { return false }
        // Look for an exact "IP Address:<ip>" token. Surrounding text
        // looks like "DNS:localhost, IP Address:127.0.0.1, IP Address:10.0.0.5".
        return r.stdout.contains("IP Address:\(ip)")
    }

    private static func shell(_ path: String, _ args: [String]) throws {
        // iOS Foundation has no Process class. Use posix_spawn directly.
        // The daemon's no-sandbox + platform-application entitlements let
        // this actually fork/exec under jailbreak.
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path)]
        argv.append(contentsOf: args.map { strdup($0) })
        argv.append(nil)
        defer { argv.forEach { if let p = $0 { free(p) } } }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw NSError(domain: "openssl", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "pipe() failed"])
        }
        let readFd = fds[0], writeFd = fds[1]

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, writeFd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFd, 2)
        posix_spawn_file_actions_addclose(&actions, readFd)
        posix_spawn_file_actions_addclose(&actions, writeFd)

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, nil, argv, environ)
        close(writeFd)
        guard rc == 0 else {
            close(readFd)
            throw NSError(domain: "openssl", code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey:
                                     "posix_spawn failed: \(String(cString: strerror(rc)))"])
        }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(readFd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        close(readFd)

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let exitStatus = (status >> 8) & 0xff
        if exitStatus != 0 {
            let s = String(data: out, encoding: .utf8) ?? ""
            throw NSError(domain: "openssl", code: Int(exitStatus),
                          userInfo: [NSLocalizedDescriptionKey: s])
        }
    }
}

private enum CertPaths {
    static let dir = "/var/mobile/Library/IOSspect"
    static let fingerprintFile = dir + "/cert.fingerprint"
}

// Daemon-side IP discovery. Duplicated from the app for now to avoid a
// cross-target import; both copies are tiny.
private enum NetworkUtilDaemon {
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

private enum UIDeviceShim {
    /// Best-effort device name for the cert CN. We don't link UIKit
    /// into the daemon, so read it from sysctl.
    static func name() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
}
