// ProcessReader.swift - iOS process listing via sysctl + proc_pidinfo.
//
// iOS has no /proc. Equivalents:
//   sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL) -> array of kinfo_proc
//   proc_pidinfo(pid, PROC_PIDTASKINFO, ...)   -> RSS, vsz, thread count
//   proc_pidpath(pid, buf, size)               -> full executable path

import Foundation
import Darwin

// libproc isn't exposed through `import Darwin` on the iOS SDK Theos
// uses, so bridge the bits needed by hand. Layouts taken from
// <sys/proc_info.h> in xnu: 6 uint64 + 12 int32 (96 bytes total).

@_silgen_name("proc_pidpath")
private func _proc_pidpath(_ pid: pid_t,
                           _ buffer: UnsafeMutableRawPointer,
                           _ bufferSize: UInt32) -> Int32

@_silgen_name("proc_pidinfo")
private func _proc_pidinfo(_ pid: pid_t,
                           _ flavor: Int32,
                           _ arg: UInt64,
                           _ buffer: UnsafeMutableRawPointer,
                           _ size: Int32) -> Int32

private let PROC_PIDTASKINFO: Int32 = 4
private let PROC_PIDPATHINFO_MAXSIZE: Int32 = 4096

private struct ProcTaskInfo {
    var pti_virtual_size:       UInt64 = 0
    var pti_resident_size:      UInt64 = 0
    var pti_total_user:         UInt64 = 0
    var pti_total_system:       UInt64 = 0
    var pti_threads_user:       UInt64 = 0
    var pti_threads_system:     UInt64 = 0
    var pti_policy:             Int32  = 0
    var pti_faults:             Int32  = 0
    var pti_pageins:            Int32  = 0
    var pti_cow_faults:         Int32  = 0
    var pti_messages_sent:      Int32  = 0
    var pti_messages_received:  Int32  = 0
    var pti_syscalls_mach:      Int32  = 0
    var pti_syscalls_unix:      Int32  = 0
    var pti_csw:                Int32  = 0
    var pti_threadnum:          Int32  = 0
    var pti_numrunning:         Int32  = 0
    var pti_priority:           Int32  = 0
}

enum ProcessReader {

    struct ProcInfo: Codable {
        let pid: Int32
        let ppid: Int32
        let uid: UInt32
        let name: String
        let cmdline: String
        let state: String
        let threads: Int32
        let rssKb: Int64
    }

    static func list() -> [ProcInfo] {
        guard let procs = fetchKinfoProcs() else { return [] }
        var out: [ProcInfo] = []
        out.reserveCapacity(procs.count)
        for var kp in procs {
            let info = decode(&kp)
            out.append(info)
        }
        // Stable ordering: newest pid first feels right for an inspector.
        return out.sorted { $0.pid > $1.pid }
    }

    // MARK: - sysctl raw fetch

    private static func fetchKinfoProcs() -> [kinfo_proc]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: size_t = 0
        // Probe required buffer size.
        if sysctl(&mib, 4, nil, &size, nil, 0) < 0 { return nil }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: count)
        let r = buf.withUnsafeMutableBufferPointer { bp -> Int32 in
            var s = size
            return sysctl(&mib, 4, bp.baseAddress, &s, nil, 0)
        }
        if r < 0 { return nil }
        return buf
    }

    // MARK: - Decode one entry

    private static func decode(_ kp: inout kinfo_proc) -> ProcInfo {
        let pid = kp.kp_proc.p_pid
        let ppid = kp.kp_eproc.e_ppid
        let uid = kp.kp_eproc.e_pcred.p_ruid
        let comm = withUnsafePointer(to: &kp.kp_proc.p_comm) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) }
        }
        let state = stateChar(kp.kp_proc.p_stat)
        let path = procPath(pid: pid)
        // proc_pidinfo for RSS + thread count. Best-effort; failing pids
        // just get zeroes (KEXTs and the kernel often refuse).
        var ti = ProcTaskInfo()
        let tiSize = Int32(MemoryLayout<ProcTaskInfo>.size)
        let n = _proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, tiSize)
        let threads: Int32 = (n == tiSize) ? ti.pti_threadnum : 0
        let rss: Int64    = (n == tiSize) ? Int64(ti.pti_resident_size) / 1024 : 0

        // cmdline: full args via KERN_PROCARGS2 returns a flat byte
        // buffer of argc + envp blobs. The executable path is enough
        // to identify a process here.
        let cmdline = path.isEmpty ? comm : path

        // Name: prefer the last path component (bundle name) over the
        // 16-char p_comm truncation when available.
        let name: String = path.isEmpty
            ? comm
            : (path as NSString).lastPathComponent

        return .init(pid: pid, ppid: ppid, uid: uid,
                     name: name, cmdline: cmdline,
                     state: state, threads: threads, rssKb: rss)
    }

    private static func procPath(pid: pid_t) -> String {
        let cap = Int(PROC_PIDPATHINFO_MAXSIZE)
        var buf = [CChar](repeating: 0, count: cap)
        let n = _proc_pidpath(pid, &buf, UInt32(cap))
        guard n > 0 else { return "" }
        return String(cString: buf)
    }

    private static func stateChar(_ s: CChar) -> String {
        // p_stat constants from <sys/proc.h>
        switch s {
        case 1: return "I"   // idle
        case 2: return "R"   // running
        case 3: return "S"   // sleep
        case 4: return "T"   // stopped
        case 5: return "Z"   // zombie
        default: return "?"
        }
    }
}
