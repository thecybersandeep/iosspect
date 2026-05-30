// FileBrowser.swift - walk the Data and Bundle containers of an
// installed app.
//
// iOS has two roots per app:
//   - data   /var/mobile/Containers/Data/Application/<UUID>/
//   - bundle /var/containers/Bundle/Application/<UUID>/<App>.app
//
// Both are surfaced under the same Files tab in the UI; the `root` query
// parameter selects which.

import Foundation

enum FileBrowser {

    enum RootKind: String { case data, bundle }

    struct Entry {
        let name: String
        let path: String       // absolute on-disk path
        let isDir: Bool
        let size: Int64
        let modifiedMs: Int64
        let kind: String       // classification: dir / text / plist / sqlite / image / binary
    }

    /// Targeted, fast lookup. Doesn't enumerate the full apps list - that
    /// can take 30+ seconds on a device with hundreds of apps + data
    /// containers. Just probes the small set of paths an iOS app could
    /// realistically be at and returns on first match.
    static func resolveRoot(pkg: String, root: RootKind) -> String? {
        switch root {
        case .bundle: return findBundlePath(pkg: pkg)
        case .data:   return findDataContainerPath(pkg: pkg)
        }
    }

    private static func findBundlePath(pkg: String) -> String? {
        let fm = FileManager.default

        // 1. System app: /Applications/<Name>.app, identified by Info.plist
        // CFBundleIdentifier. Limit iteration cost by reading only the plist.
        for sysBase in ["/Applications", "/var/jb/Applications"] {
            if let entries = try? fm.contentsOfDirectory(atPath: sysBase) {
                for d in entries where d.hasSuffix(".app") {
                    let p = sysBase + "/" + d
                    let info = NSDictionary(contentsOfFile: p + "/Info.plist") as? [String: Any]
                    if (info?["CFBundleIdentifier"] as? String) == pkg { return p }
                }
            }
        }

        // 2. User app: /var/containers/Bundle/Application/<UUID>/<Name>.app
        let userBase = "/var/containers/Bundle/Application"
        if let uuids = try? fm.contentsOfDirectory(atPath: userBase) {
            for u in uuids {
                let uuidDir = userBase + "/" + u
                guard let appName = (try? fm.contentsOfDirectory(atPath: uuidDir))?.first(where: { $0.hasSuffix(".app") }) else { continue }
                let p = uuidDir + "/" + appName
                let info = NSDictionary(contentsOfFile: p + "/Info.plist") as? [String: Any]
                if (info?["CFBundleIdentifier"] as? String) == pkg { return p }
            }
        }
        return nil
    }

    private static func findDataContainerPath(pkg: String) -> String? {
        let fm = FileManager.default
        let base = "/var/mobile/Containers/Data/Application"
        guard let uuids = try? fm.contentsOfDirectory(atPath: base) else { return nil }
        // Walk container UUIDs, early-exit on match.
        for u in uuids {
            let meta = base + "/" + u + "/.com.apple.mobile_container_manager.metadata.plist"
            if let d = NSDictionary(contentsOfFile: meta) as? [String: Any],
               (d["MCMMetadataIdentifier"] as? String) == pkg {
                return base + "/" + u
            }
        }
        return nil
    }

    static func list(pkg: String, relative: String, root: RootKind) throws -> (root: String, entries: [Entry]) {
        guard let base = resolveRoot(pkg: pkg, root: root) else {
            throw FileBrowserError("no \(root.rawValue) container for \(pkg)")
        }
        let target = try Sanitize.safePathUnder(base: base, relative: relative)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target, isDirectory: &isDir) else {
            throw FileBrowserError("path not found: \(relative)")
        }
        guard isDir.boolValue else {
            throw FileBrowserError("not a directory: \(relative)")
        }
        let names = (try? fm.contentsOfDirectory(atPath: target)) ?? []
        var out: [Entry] = []
        for n in names.sorted() {
            let p = (target as NSString).appendingPathComponent(n)
            let attrs = (try? fm.attributesOfItem(atPath: p)) ?? [:]
            let entryIsDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            out.append(Entry(
                name: n,
                path: p,
                isDir: entryIsDir,
                size: size,
                modifiedMs: Int64(mtime * 1000),
                kind: classify(name: n, isDir: entryIsDir)
            ))
        }
        // Directories first, then alphabetical.
        out.sort {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.lowercased() < $1.name.lowercased()
        }
        return (base, out)
    }

    static func readBytes(pkg: String, relative: String, root: RootKind, max: Int = 5_000_000) throws -> Data {
        guard let base = resolveRoot(pkg: pkg, root: root) else {
            throw FileBrowserError("no \(root.rawValue) container for \(pkg)")
        }
        let target = try Sanitize.safePathUnder(base: base, relative: relative)
        guard let fh = FileHandle(forReadingAtPath: target) else {
            throw FileBrowserError("cannot open: \(relative)")
        }
        defer { try? fh.close() }
        return fh.readData(ofLength: max)
    }

    /// Same vocabulary as Android's classifier so the web UI's icon
    /// mapping works unchanged.
    private static func classify(name: String, isDir: Bool) -> String {
        if isDir { return "dir" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "plist":                                              return "plist"
        case "sqlite", "sqlite3", "db", "db-wal", "db-shm":        return "sqlite"
        case "txt", "json", "xml", "yaml", "yml", "md", "log",
             "ini", "conf", "csv":                                 return "text"
        case "html", "htm", "css", "js":                           return "text"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "ktx":   return "image"
        case "mp3", "wav", "m4a", "aac":                           return "audio"
        case "mp4", "mov", "m4v":                                  return "video"
        case "pdf":                                                return "pdf"
        case "dylib", "so", "framework":                           return "native"
        default:                                                   return "binary"
        }
    }
}

struct FileBrowserError: Error, LocalizedError {
    let message: String
    init(_ m: String) { self.message = m }
    var errorDescription: String? { message }
}
