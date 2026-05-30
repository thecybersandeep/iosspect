// LogcatStreamer.swift - live device log feed.
//
// Tails /var/log/com.apple.xpc.launchd/launchd.log into an in-memory
// ring buffer. The web UI polls /api/live/logcat?from=N for incremental
// chunks.

import Foundation
import Darwin

final class LogcatStreamer {

    // Singleton: only one tail per daemon. Lines from every poller pull
    // from the same ring.
    static let shared = LogcatStreamer()

    private let queue = DispatchQueue(label: "iosspect.logcat", qos: .utility)
    private var pid: pid_t = 0
    private var readFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var partial = Data()  // accumulator for "no newline yet" tail

    // Ring buffer of the most recent ~2K lines. Each line is tagged
    // with a monotonic sequence so pollers can dedupe.
    private let maxLines = 2_000
    private var ring: [(seq: Int64, line: String)] = []
    private var nextSeq: Int64 = 1
    private let ringLock = NSLock()

    private init() {}

    // MARK: - Public API

    /// Spawn `log stream` if it isn't already running. Idempotent.
    @discardableResult
    func startIfNeeded() -> Bool {
        ringLock.lock()
        if pid != 0 { ringLock.unlock(); return true }
        ringLock.unlock()
        return spawn()
    }

    /// Pull every line with seq > `from`. Returns the lines plus the
    /// new `nextFrom` cursor.
    func read(from: Int64, limit: Int = 500, filter: String? = nil, pid: Int32? = nil)
        -> (lines: [(seq: Int64, line: String)], nextFrom: Int64)
    {
        ringLock.lock()
        let snap = ring
        ringLock.unlock()
        var out: [(Int64, String)] = []
        var cursor = from
        for (s, l) in snap where s > from {
            cursor = s
            if let f = filter, !f.isEmpty, !l.localizedCaseInsensitiveContains(f) { continue }
            if let p = pid, p > 0 {
                // log stream prefixes the pid in brackets, e.g. "...[1234]:"
                if !l.contains("[\(p)]:") { continue }
            }
            out.append((s, l))
            if out.count >= limit { break }
        }
        return (out, cursor)
    }

    /// Total lines currently buffered (debug/diagnostics).
    func bufferedCount() -> Int {
        ringLock.lock(); defer { ringLock.unlock() }
        return ring.count
    }

    // MARK: - spawn

    private func spawn() -> Bool {
        // Apple's `log` CLI is macOS-only and the unified-log tracev3
        // files under /var/db/diagnostics/ would need a 1000+ line
        // parser. Tail the plaintext log launchd writes to
        // /var/log/com.apple.xpc.launchd/launchd.log instead. Not every
        // app's logs, but the most active live source available without
        // pulling in private frameworks. It surfaces launchd-mediated
        // app crashes, spawns and signals.
        let tailBin = ["/var/jb/usr/bin/tail", "/usr/bin/tail"]
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let path = tailBin else {
            fputs("LogcatStreamer: tail binary not found\n", stderr)
            return false
        }
        let candidates = [
            "/var/log/com.apple.xpc.launchd/launchd.log",
            "/var/jb/var/log/com.apple.xpc.launchd/launchd.log"
        ]
        guard let logFile = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            fputs("LogcatStreamer: no readable launchd log\n", stderr)
            return false
        }
        // -F follows the file across truncation/rotation. -n 200 seeds
        // the buffer with recent history so the user isn't staring at
        // an empty window on first open.
        let argv: [String] = [path, "-F", "-n", "200", logFile]
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        defer { cArgv.forEach { if let p = $0 { free(p) } } }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return false }
        let r = fds[0], w = fds[1]

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, w, 1)
        posix_spawn_file_actions_adddup2(&actions, w, 2)
        posix_spawn_file_actions_addclose(&actions, r)
        posix_spawn_file_actions_addclose(&actions, w)

        var p: pid_t = 0
        let rc = posix_spawn(&p, path, &actions, nil, cArgv, environ)
        close(w)
        guard rc == 0 else {
            close(r)
            fputs("LogcatStreamer: posix_spawn errno=\(rc)\n", stderr)
            return false
        }

        // Wire stdout into a dispatch source on a background queue.
        let src = DispatchSource.makeReadSource(fileDescriptor: r, queue: queue)
        src.setEventHandler { [weak self] in self?.drain(r) }
        src.setCancelHandler { close(r) }
        src.resume()

        ringLock.lock()
        self.pid = p
        self.readFd = r
        self.readSource = src
        ringLock.unlock()

        fputs("LogcatStreamer: started log stream pid=\(p)\n", stdout)
        return true
    }

    /// Hard cap on `partial`. A single multi-MB log line with no
    /// newline would otherwise grow this buffer until OOM.
    private let maxPartial = 64 * 1024

    private func drain(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        // Disambiguate from Sequence.read. The POSIX syscall is wanted here.
        let n = Darwin.read(fd, &buf, buf.count)
        if n <= 0 { return }
        partial.append(buf, count: n)
        // Split on newlines, leaving any trailing non-terminated tail
        // for the next read.
        while let nl = partial.firstIndex(of: 0x0a) {
            let lineData = partial.subdata(in: 0..<nl)
            partial.removeSubrange(0...nl)
            let line = String(data: lineData, encoding: .utf8)
                    ?? String(data: lineData, encoding: .isoLatin1)
                    ?? ""
            if line.isEmpty { continue }
            push(line)
        }
        // If a line ever exceeds the cap without a newline, force-flush
        // what we have so memory stays bounded.
        if partial.count > maxPartial {
            let head = partial.prefix(maxPartial)
            let line = (String(data: head, encoding: .utf8)
                     ?? String(data: head, encoding: .isoLatin1)
                     ?? "") + " ...(truncated)"
            push(line)
            partial.removeAll(keepingCapacity: false)
        }
    }

    private func push(_ line: String) {
        ringLock.lock(); defer { ringLock.unlock() }
        ring.append((nextSeq, line))
        nextSeq += 1
        if ring.count > maxLines {
            ring.removeFirst(ring.count - maxLines)
        }
    }
}
