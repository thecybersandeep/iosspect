// ZipWriter.swift - streaming in-process ZIP writer.
//
// Used by /api/apps/{pkg}/files/zip and /api/apps/{pkg}/apk to package
// directories for download. STORE only (method 0), so no zlib link from
// Swift. Each source file is streamed in 64 KB chunks straight to the
// output FileHandle, keeping memory bounded regardless of archive size.
//
// Format reminder:
//   per entry:  local file header  +  raw bytes
//   tail:       central directory headers (one per entry)  +  EOCD
// CRC-32 of the file body is required even for STORE.

import Foundation
import Darwin

enum ZipWriter {

    /// Diagnostic log. Flushed immediately so a subsequent crash does
    /// not lose the last line. Prefixed for grepability.
    private static func log(_ msg: String) {
        fputs("ZipWriter: \(msg)\n", stderr)
        fflush(stderr)
    }

    /// Stream a directory into a new .zip at `out`. Returns the byte
    /// count on success, nil on any IO failure. Caller is responsible
    /// for cleaning up `out` after consuming it.
    /// Hard ceilings prevent an authenticated attacker from filling
    /// /private/var/tmp with a request that zips an absurd target
    /// (`/` or the system Photos library).
    static let maxArchiveBytes: Int64 = 2_000_000_000   // 2 GB
    static let maxEntries: Int = 50_000

    @discardableResult
    static func writeDirectory(root: String, baseLabel: String, out: URL) -> Int64? {
        let fm = FileManager.default
        var rootIsDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &rootIsDir) else { return nil }

        if fm.fileExists(atPath: out.path) {
            try? fm.removeItem(at: out)
        }
        fm.createFile(atPath: out.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: out) else { return nil }
        defer { try? fh.close() }

        var files: [(rel: String, abs: String)] = []
        if rootIsDir.boolValue {
            var stack = [(prefix: baseLabel, dir: root)]
            while let (prefix, dir) = stack.popLast() {
                guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for n in names.sorted() {
                    let full = "\(dir)/\(n)"
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                    if isDir.boolValue {
                        stack.append((prefix: "\(prefix)/\(n)", dir: full))
                    } else {
                        files.append((rel: "\(prefix)/\(n)", abs: full))
                    }
                }
            }
        } else {
            files.append((rel: baseLabel, abs: root))
        }

        guard files.count <= maxEntries else {
            log("refusing: \(files.count) entries exceeds maxEntries=\(maxEntries)")
            return nil
        }

        var central = Data()
        var entries: UInt16 = 0
        var written: UInt64 = 0

        for f in files {
            if written > UInt64(maxArchiveBytes) {
                log("refusing: archive size \(written) exceeds maxArchiveBytes=\(maxArchiveBytes)")
                return nil
            }
            do {
                let info = try streamEntry(into: fh,
                                            path: f.abs,
                                            name: f.rel,
                                            localOffset: UInt32(written))
                guard let info else {
                    log("skip-open \(f.rel)")
                    continue
                }
                central.append(info.centralRecord)
                written = UInt64(info.endOffset)
                entries &+= 1
            } catch {
                log("skip-error \(f.rel): \(error)")
                continue
            }
        }

        do {
            let cdStart = UInt32(written)
            try writeAll(fh, central)
            let cdSize = UInt32(central.count)
            try writeAll(fh, eocd(centralStart: cdStart, centralSize: cdSize, entryCount: entries))
            return Int64(written + UInt64(cdSize) + UInt64(22))
        } catch {
            fputs("ZipWriter: failed to finalise: \(error)\n", stderr)
            return nil
        }
    }

    /// Wrap the throwing write so callers don't have to reach for
    /// availability checks. Falls back to the legacy non-throwing write
    /// only when the new API isn't there.
    private static func writeAll(_ fh: FileHandle, _ data: Data) throws {
        if #available(iOS 13.4, *) {
            try fh.write(contentsOf: data)
        } else {
            fh.write(data)
        }
    }

    // MARK: - per-entry stream

    private struct EntryInfo {
        let centralRecord: Data
        let endOffset: Int
    }

    /// Open a single source file, compute CRC + length, write its local
    /// header, then stream the bytes. POSIX open/read via Darwin rather
    /// than Foundation.FileHandle: the latter reliably kills the daemon
    /// mid-CRC on 25 MB files under rootless palera1n with no log and
    /// no crash report.
    private static func streamEntry(into fh: FileHandle,
                                     path: String,
                                     name: String,
                                     localOffset: UInt32) throws -> EntryInfo? {
        let fd = path.withCString { open($0, O_RDONLY) }
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // Two-pass: compute CRC + total size, then rewind and stream
        // out. 64 KB chunk size sits well inside any reasonable
        // allocation limit so a malloc spike cannot trigger a fatal.
        let bufSize = 64 * 1024
        var buf = [UInt8](repeating: 0, count: bufSize)

        var crc: UInt32 = 0xFFFFFFFF
        var total: UInt32 = 0
        while true {
            let n = buf.withUnsafeMutableBufferPointer {
                Darwin.read(fd, $0.baseAddress, bufSize)
            }
            if n <= 0 { break }
            for i in 0..<n {
                let idx = Int((crc ^ UInt32(buf[i])) & 0xff)
                crc = crcTable[idx] ^ (crc >> 8)
            }
            total &+= UInt32(n)
        }
        crc ^= 0xFFFFFFFF

        // Rewind via lseek for the streaming write pass.
        _ = lseek(fd, 0, SEEK_SET)

        let nameBytes = Data(name.utf8)
        let lfh = localFileHeader(name: nameBytes, crc: crc, size: total)
        try writeAll(fh, lfh)
        var written = Int(localOffset) + lfh.count
        while true {
            let n = buf.withUnsafeMutableBufferPointer {
                Darwin.read(fd, $0.baseAddress, bufSize)
            }
            if n <= 0 { break }
            let chunk = Data(bytes: buf, count: n)
            try writeAll(fh, chunk)
            written += n
        }
        let cdh = centralDirHeader(name: nameBytes, crc: crc,
                                    size: total, localOffset: localOffset)
        return EntryInfo(centralRecord: cdh, endOffset: written)
    }

    // MARK: - record builders

    private static let signLFH:  UInt32 = 0x04034b50
    private static let signCDH:  UInt32 = 0x02014b50
    private static let signEOCD: UInt32 = 0x06054b50

    private static func localFileHeader(name: Data, crc: UInt32, size: UInt32) -> Data {
        var h = Data()
        h.appendLE(signLFH)
        h.appendLE(UInt16(20))                  // version needed
        h.appendLE(UInt16(0))                   // general purpose bit flag
        h.appendLE(UInt16(0))                   // method = STORE
        h.appendLE(UInt16(0))                   // last mod time
        h.appendLE(UInt16(0))                   // last mod date
        h.appendLE(crc)
        h.appendLE(size)                        // compressed size
        h.appendLE(size)                        // uncompressed size
        h.appendLE(UInt16(name.count))
        h.appendLE(UInt16(0))                   // extra field length
        h.append(name)
        return h
    }

    private static func centralDirHeader(name: Data, crc: UInt32, size: UInt32, localOffset: UInt32) -> Data {
        var h = Data()
        h.appendLE(signCDH)
        h.appendLE(UInt16(20))                  // version made by
        h.appendLE(UInt16(20))                  // version needed
        h.appendLE(UInt16(0))                   // flags
        h.appendLE(UInt16(0))                   // method
        h.appendLE(UInt16(0))                   // time
        h.appendLE(UInt16(0))                   // date
        h.appendLE(crc)
        h.appendLE(size)
        h.appendLE(size)
        h.appendLE(UInt16(name.count))
        h.appendLE(UInt16(0))                   // extra
        h.appendLE(UInt16(0))                   // comment
        h.appendLE(UInt16(0))                   // disk number
        h.appendLE(UInt16(0))                   // internal attrs
        h.appendLE(UInt32(0))                   // external attrs
        h.appendLE(localOffset)
        h.append(name)
        return h
    }

    private static func eocd(centralStart: UInt32, centralSize: UInt32, entryCount: UInt16) -> Data {
        var h = Data()
        h.appendLE(signEOCD)
        h.appendLE(UInt16(0))                   // disk number
        h.appendLE(UInt16(0))                   // central dir start disk
        h.appendLE(entryCount)
        h.appendLE(entryCount)
        h.appendLE(centralSize)
        h.appendLE(centralStart)
        h.appendLE(UInt16(0))                   // comment len
        return h
    }

    // MARK: - CRC-32 (IEEE)

    private static let crcTable: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c: UInt32 = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            t[i] = c
        }
        return t
    }()
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
