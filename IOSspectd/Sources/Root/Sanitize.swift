// Sanitize.swift - input validation for anything that hits a shell or
// gets joined into a path.

import Foundation

enum Sanitize {

    /// Bundle id (com.example.app). Same shape Apple enforces at
    /// install time. Hand-validated instead of NSRegularExpression so a
    /// regex-init failure at module-init cannot abort the daemon before
    /// the run loop ever starts.
    static func bundleId(_ s: String) throws -> String {
        guard !s.isEmpty, s.count <= 128 else {
            throw SanitizeError("invalid bundle id: \(s)")
        }
        let first = s.unicodeScalars.first!
        guard CharacterSet.letters.contains(first) else {
            throw SanitizeError("invalid bundle id: \(s)")
        }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-"))
        for u in s.unicodeScalars where !allowed.contains(u) {
            throw SanitizeError("invalid bundle id: \(s)")
        }
        return s
    }

    /// Single-quote a value for `/bin/sh -c`. Embedded single quotes get
    /// the standard `'\''` dance.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Resolve `relative` against `base` and verify the result stays
    /// under `base`. Rejects `..` traversal and sibling-string-prefix
    /// confusion (`/foo` allowing `/foo-evil`) by enforcing a
    /// path-component boundary.
    static func safePathUnder(base: String, relative: String) throws -> String {
        let joined = (base as NSString).appendingPathComponent(relative)
        let canonical = (joined as NSString).standardizingPath
        let safeBase = base.hasSuffix("/") ? base : base + "/"
        // Either the resolved path IS the base (relative == "") or it
        // sits underneath the base joined by a separator. A bare hasPrefix
        // would let "/foo/Bar.app-evil" match base "/foo/Bar.app".
        guard canonical == base || canonical.hasPrefix(safeBase) else {
            throw SanitizeError("path escapes root: \(relative)")
        }
        return canonical
    }

    /// Pull `<pkg>` out of a `/api/apps/<pkg>/...` URL path and validate
    /// it as a bundle id. Returns nil on shape mismatch or invalid id;
    /// callers turn that into a 400.
    static func extractPkg(fromPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "api", parts[1] == "apps" else { return nil }
        return try? Sanitize.bundleId(parts[2])
    }

}

struct SanitizeError: Error, LocalizedError {
    let message: String
    init(_ m: String) { self.message = m }
    var errorDescription: String? { message }
}
