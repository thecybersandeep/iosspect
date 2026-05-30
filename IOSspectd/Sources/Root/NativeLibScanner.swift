// NativeLibScanner.swift - list the Mach-O slices that make up an app.
//
// Sources:
//   <bundle>/<App>                  the main executable, Mach-O
//   <bundle>/Frameworks/*.dylib     embedded dylibs
//   <bundle>/Frameworks/*.framework binary inside is Mach-O
//   <bundle>/PlugIns/*.appex        each extension is its own Mach-O
//
// Per slice: size, arch (arm64 / arm64e / x86_64 sim), stripped (no
// symbol table), encrypted (LC_ENCRYPTION_INFO_64 cryptid), and path.
import Foundation
import Darwin

enum NativeLibScanner {

    struct Lib: Codable {
        let name: String
        let path: String
        let size: Int64
        let arch: String
        let stripped: Bool
        let encrypted: Bool
    }

    static func scan(bundlePath: String) -> [Lib] {
        var out: [Lib] = []
        let fm = FileManager.default

        // Main binary: read CFBundleExecutable from Info.plist, fall
        // back to the .app's last path component (Apple-built apps
        // follow that convention so this works for "iBooks.app/iBooks").
        if let mainName = mainExecName(bundlePath: bundlePath) {
            let mainPath = "\(bundlePath)/\(mainName)"
            if fm.fileExists(atPath: mainPath) {
                out.append(probe(path: mainPath, name: mainName))
            }
        }

        // Frameworks/. Entries can be either:
        //   *.dylib       a single Mach-O at that path
        //   *.framework   a directory; binary is <name>.framework/<name>
        let fwDir = "\(bundlePath)/Frameworks"
        if let entries = try? fm.contentsOfDirectory(atPath: fwDir) {
            for e in entries.sorted() {
                let p = "\(fwDir)/\(e)"
                if e.hasSuffix(".dylib") {
                    out.append(probe(path: p, name: e))
                } else if e.hasSuffix(".framework") {
                    let inner = (e as NSString).deletingPathExtension
                    let bin = "\(p)/\(inner)"
                    if fm.fileExists(atPath: bin) {
                        out.append(probe(path: bin, name: e))
                    }
                }
            }
        }

        // PlugIns/. Each .appex is a tiny app bundle of its own.
        let plDir = "\(bundlePath)/PlugIns"
        if let entries = try? fm.contentsOfDirectory(atPath: plDir) {
            for e in entries.sorted() where e.hasSuffix(".appex") {
                let appex = "\(plDir)/\(e)"
                if let exec = mainExecName(bundlePath: appex) {
                    let bin = "\(appex)/\(exec)"
                    if fm.fileExists(atPath: bin) {
                        out.append(probe(path: bin, name: e))
                    }
                }
            }
        }
        return out
    }

    // MARK: - Per-binary probe

    private static func probe(path: String, name: String) -> Lib {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        var arch = "unknown"
        var stripped = false
        var encrypted = false

        // Read enough header to interpret load commands. Most LC_*
        // sequences fit in the first 64 KB.
        if let fh = FileHandle(forReadingAtPath: path) {
            let header = fh.readData(ofLength: 96 * 1024)
            try? fh.close()
            if let r = inspect(header) {
                arch = r.arch
                stripped = r.stripped
                encrypted = r.encrypted
            }
        }
        return Lib(name: name, path: path, size: size,
                   arch: arch, stripped: stripped, encrypted: encrypted)
    }

    private struct Inspection { let arch: String; let stripped: Bool; let encrypted: Bool }

    /// Parse the first slice of a (FAT or thin) Mach-O. Reads enough load
    /// commands to fill in arch + symtab + encryption info.
    private static func inspect(_ data: Data) -> Inspection? {
        guard data.count >= 4 else { return nil }
        let magic: UInt32 = data.withUnsafeBytes { $0.load(as: UInt32.self) }

        // FAT magic. Pick the first slice and recurse. Big-endian.
        if magic == 0xCAFEBABE || magic == 0xBEBAFECA {
            let bigEndian = (magic == 0xCAFEBABE)
            guard data.count >= 8 else { return nil }
            let nfatRaw: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
            let nfat = bigEndian ? nfatRaw.bigEndian : nfatRaw
            guard nfat > 0, data.count >= 8 + 20 else { return nil }
            let offRaw: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 8 + 8, as: UInt32.self) }
            let off = Int(bigEndian ? offRaw.bigEndian : offRaw)
            guard off < data.count else { return nil }
            return inspect(data.subdata(in: off..<data.count))
        }

        // 64-bit Mach-O (little endian for arm64 / arm64e / x86_64).
        guard magic == 0xFEEDFACF else { return nil }
        // mach_header_64 is 32 bytes:
        //   uint32 magic, int32 cputype, int32 cpusubtype, uint32 filetype,
        //   uint32 ncmds, uint32 sizeofcmds, uint32 flags, uint32 reserved
        guard data.count >= 32 else { return nil }
        let cputype: Int32      = data.withUnsafeBytes { $0.load(fromByteOffset: 4,  as: Int32.self) }
        let cpusubtype: UInt32  = data.withUnsafeBytes { $0.load(fromByteOffset: 8,  as: UInt32.self) }
        let ncmds: UInt32       = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }

        // arch
        let arch: String = {
            let CPU_TYPE_ARM64: Int32 = 0x0100000C
            let CPU_TYPE_X86_64: Int32 = 0x01000007
            switch cputype {
            case CPU_TYPE_ARM64:
                // arm64e has subtype 2, arm64 plain has subtype 0/1.
                let sub = cpusubtype & 0x00FFFFFF
                return sub == 2 ? "arm64e" : "arm64"
            case CPU_TYPE_X86_64: return "x86_64"
            default: return "cpu(\(cputype))"
            }
        }()

        // Walk load commands looking for LC_SYMTAB (=0x02) and
        // LC_ENCRYPTION_INFO_64 (=0x2C). Each lc starts with uint32 cmd,
        // uint32 cmdsize.
        var hasSymtabWithSyms = false
        var encrypted = false
        var cursor = 32  // after mach_header_64
        let LC_SYMTAB: UInt32 = 0x02
        let LC_ENCRYPTION_INFO_64: UInt32 = 0x2C
        for _ in 0..<min(Int(ncmds), 1024) {
            guard cursor + 8 <= data.count else { break }
            let cmd: UInt32     = data.withUnsafeBytes { $0.load(fromByteOffset: cursor, as: UInt32.self) }
            let cmdsize: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: cursor + 4, as: UInt32.self) }
            if cmd == LC_SYMTAB && cmdsize >= 24 && cursor + 16 <= data.count {
                // symtab_command.nsyms at +8
                let nsyms: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: cursor + 12, as: UInt32.self) }
                if nsyms > 0 { hasSymtabWithSyms = true }
            } else if cmd == LC_ENCRYPTION_INFO_64 && cmdsize >= 24 && cursor + 20 <= data.count {
                // encryption_info_command_64.cryptid at +16
                let cryptid: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: cursor + 16, as: UInt32.self) }
                if cryptid != 0 { encrypted = true }
            }
            cursor += Int(cmdsize)
            if cmdsize == 0 { break }
        }
        return Inspection(arch: arch, stripped: !hasSymtabWithSyms, encrypted: encrypted)
    }

    private static func mainExecName(bundlePath: String) -> String? {
        let plist = "\(bundlePath)/Info.plist"
        if let dict = NSDictionary(contentsOfFile: plist) as? [String: Any],
           let s = dict["CFBundleExecutable"] as? String {
            return s
        }
        return (bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }
}
