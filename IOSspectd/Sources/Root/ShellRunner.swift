// ShellRunner.swift - posix_spawn-based shell exec.
//
// Foundation.Process is macOS-only. iOS daemons drive subprocesses via
// posix_spawn + a manual pipe + waitpid. The daemon runs as root via
// launchd, so /bin/sh -c is the simplest way to give the user the same
// kind of REPL they'd get from SSH.

import Foundation
import Darwin

enum ShellRunner {

    struct Result {
        let stdout: String
        let stderr: String
        let code: Int32
        let timedOut: Bool
    }

    /// Run `cmd` via `/bin/sh -c` with a hard timeout. Captures stdout
    /// and stderr separately. Output is decoded as UTF-8, falling back
    /// to ISO-Latin-1 so binary spillage still shows something.
    static func sh(_ cmd: String, timeoutSec: Double = 10.0) -> Result {
        // Locate sh. Rootless variants ship it under /var/jb/bin.
        let shPath = ["/var/jb/bin/sh", "/bin/sh"]
            .first { FileManager.default.fileExists(atPath: $0) }
            ?? "/bin/sh"

        let argv: [String] = [shPath, "-c", cmd]
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        defer { cArgv.forEach { if let p = $0 { free(p) } } }

        // Two pipes so the UI can colour stdout and stderr separately.
        var outFds: [Int32] = [0, 0]
        var errFds: [Int32] = [0, 0]
        guard pipe(&outFds) == 0, pipe(&errFds) == 0 else {
            return .init(stdout: "", stderr: "pipe() failed", code: -1, timedOut: false)
        }
        let outR = outFds[0], outW = outFds[1]
        let errR = errFds[0], errW = errFds[1]

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, outW, 1)
        posix_spawn_file_actions_adddup2(&actions, errW, 2)
        posix_spawn_file_actions_addclose(&actions, outR)
        posix_spawn_file_actions_addclose(&actions, outW)
        posix_spawn_file_actions_addclose(&actions, errR)
        posix_spawn_file_actions_addclose(&actions, errW)

        // Build an env that widens PATH so common tools (id, ls, ps,
        // grep, netstat, dpkg, etc.) resolve. launchd hands daemons a
        // minimal PATH = /usr/bin:/bin:/usr/sbin:/sbin which on rootless
        // jailbreaks does not contain the actual binaries; those live
        // under /var/jb. Build envp by copying environ and overriding PATH.
        let extendedPath = "/var/jb/usr/local/bin:/var/jb/usr/sbin:/var/jb/usr/bin:/var/jb/bin:/var/jb/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        var envStrings: [String] = []
        var i = 0
        // `environ` is a non-optional pointer whose elements are optional;
        // walk until we hit the NULL terminator.
        while let raw = environ[i] {
            let entry = String(cString: raw)
            if !entry.hasPrefix("PATH=") { envStrings.append(entry) }
            i += 1
        }
        envStrings.append("PATH=\(extendedPath)")
        var cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
        cEnv.append(nil)
        defer { cEnv.forEach { if let p = $0 { free(p) } } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, shPath, &actions, nil, cArgv, cEnv)
        close(outW); close(errW)
        guard rc == 0 else {
            close(outR); close(errR)
            return .init(stdout: "", stderr: "posix_spawn errno=\(rc)", code: -1, timedOut: false)
        }

        // Make reads non-blocking so we can poll both pipes plus waitpid
        // inside one loop with a hard deadline.
        let outFlags = fcntl(outR, F_GETFL, 0); _ = fcntl(outR, F_SETFL, outFlags | O_NONBLOCK)
        let errFlags = fcntl(errR, F_GETFL, 0); _ = fcntl(errR, F_SETFL, errFlags | O_NONBLOCK)

        var outBuf = Data(), errBuf = Data()
        var buf = [UInt8](repeating: 0, count: 8 * 1024)
        var status: Int32 = 0
        var exited = false
        var timedOut = false
        let start = Date()

        while Date().timeIntervalSince(start) < timeoutSec {
            let wpid = waitpid(pid, &status, WNOHANG)
            if wpid == pid { exited = true }
            let n1 = read(outR, &buf, buf.count); if n1 > 0 { outBuf.append(buf, count: n1) }
            let n2 = read(errR, &buf, buf.count); if n2 > 0 { errBuf.append(buf, count: n2) }
            if exited && n1 <= 0 && n2 <= 0 { break }
            usleep(20_000) // 20 ms
        }
        if !exited {
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
            timedOut = true
        }
        // Drain any tail bytes left after exit.
        while true {
            let n1 = read(outR, &buf, buf.count); if n1 > 0 { outBuf.append(buf, count: n1) } else { break }
        }
        while true {
            let n2 = read(errR, &buf, buf.count); if n2 > 0 { errBuf.append(buf, count: n2) } else { break }
        }
        close(outR); close(errR)

        let exit = (status >> 8) & 0xff
        let so = String(data: outBuf, encoding: .utf8)
               ?? String(data: outBuf, encoding: .isoLatin1) ?? ""
        let se = String(data: errBuf, encoding: .utf8)
               ?? String(data: errBuf, encoding: .isoLatin1) ?? ""
        return .init(stdout: so, stderr: se, code: exit, timedOut: timedOut)
    }
}
