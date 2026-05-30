// PlistReader.swift - generic plist decoder + NSUserDefaults browser.
//
// Two uses:
//   1. Decode any single plist file (Info.plist, embedded.mobileprovision,
//      arbitrary file in the data container).
//   2. Enumerate every plist under <data>/Library/Preferences/ which on
//      iOS is the NSUserDefaults storage.

import Foundation

enum PlistReader {

    struct TypedEntry {
        let kind: String       // string | int | bool | float | date | data | array | dict
        let value: Any         // already JSON-serialisable form
    }

    /// Decode an arbitrary plist file (xml or binary). Returns the
    /// top-level dictionary keyed `<key>` -> TypedEntry. Arrays/dicts
    /// recurse and are represented as nested [String:Any]/[Any] so the
    /// browser can JSON.stringify them.
    static func decodeFile(_ path: String) -> [String: TypedEntry]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return decodeData(data)
    }

    static func decodeData(_ data: Data) -> [String: TypedEntry]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        guard let dict = plist as? [String: Any] else { return nil }
        var out: [String: TypedEntry] = [:]
        for (k, v) in dict {
            out[k] = TypedEntry(kind: classify(v), value: jsonable(v))
        }
        return out
    }

    /// Enumerate NSUserDefaults files for the app.
    /// Returns: [bucketFilename: [key: TypedEntry]]
    static func readTyped(pkgDataDir: String) -> [String: [String: TypedEntry]] {
        let prefsDir = pkgDataDir + "/Library/Preferences"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: prefsDir) else { return [:] }
        var out: [String: [String: TypedEntry]] = [:]
        for n in names where n.hasSuffix(".plist") {
            if let parsed = decodeFile(prefsDir + "/" + n) {
                out[n] = parsed
            }
        }
        return out
    }

    /// Round-trip write a single key. Force-stop the target first so its
    /// in-memory NSUserDefaults flushes on next launch.
    @discardableResult
    static func upsert(pkgDataDir: String,
                       bucket: String,
                       key: String,
                       value: Any?,
                       typeHint: String?) -> Bool {
        let path = pkgDataDir + "/Library/Preferences/" + bucket
        var dict: [String: Any] = (NSDictionary(contentsOfFile: path) as? [String: Any]) ?? [:]
        if value == nil {
            dict.removeValue(forKey: key)
        } else {
            dict[key] = coerce(value!, typeHint: typeHint)
        }
        let ns = dict as NSDictionary
        return ns.write(toFile: path, atomically: true)
    }

    // MARK: - Internal

    private static func classify(_ v: Any) -> String {
        if v is NSNumber {
            let n = v as! NSNumber
            // CFBoolean check via type id.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return "bool" }
            // Heuristic: floating point types vs integer.
            let dv = n.doubleValue
            return dv == floor(dv) ? "int" : "float"
        }
        if v is String { return "string" }
        if v is Data   { return "data" }
        if v is Date   { return "date" }
        if v is [Any]  { return "array" }
        if v is [String: Any] { return "dict" }
        return "string"
    }

    /// Make a value JSON-encodable. Dates -> ISO 8601 string,
    /// Data -> base64 string, nested dicts/arrays recurse.
    private static func jsonable(_ v: Any) -> Any {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            return n
        }
        if let s = v as? String { return s }
        if let d = v as? Date {
            let f = ISO8601DateFormatter()
            return f.string(from: d)
        }
        if let d = v as? Data { return d.base64EncodedString() }
        if let a = v as? [Any] { return a.map { jsonable($0) } }
        if let d = v as? [String: Any] { return d.mapValues { jsonable($0) } }
        return "\(v)"
    }

    private static func coerce(_ value: Any, typeHint: String?) -> Any {
        guard let hint = typeHint else { return value }
        let s = "\(value)"
        switch hint {
        case "int":    return Int(s) ?? value
        case "bool":   return (s == "true" || s == "1") as Any
        case "float":  return Double(s) ?? value
        case "string": return s
        default:       return value
        }
    }
}
