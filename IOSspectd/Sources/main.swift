// main.swift - daemon entry point. Loaded by launchd as root.

import Foundation
import Darwin

setbuf(stdout, nil)
// Tighten the daemon umask so files we create (sessions.json,
// ratelimit.json, openssl artefacts, the temp .ipa we stream) land at
// 0600/0700 instead of 0644/0755.
umask(0o077)
fputs("IOSspect daemon starting, pid \(getpid())\n", stdout)

// MARK: - State helpers
//
// Two files under /var/mobile/Library/IOSspect:
//   control: app drops "start" | "stop" | "restart"
//   state:   daemon writes "running" | "stopped" so the app's
//            indicator reflects reality without probing the TCP port.
//
// control is consumed (deleted) every poll. state persists across
// daemon restarts so a Stop survives reboot.

let stateDir    = "/var/mobile/Library/IOSspect"
let controlFile = "\(stateDir)/control"
let stateFile   = "\(stateDir)/state"

func writeState(_ s: String) {
    try? s.write(toFile: stateFile, atomically: true, encoding: .utf8)
    // 0644 root:wheel: readable by the mobile-uid app, writable only
    // by us. A mobile-writable state file would let any sandboxed app
    // stop the daemon on next boot by writing "stopped".
    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stateFile)
}

func desiredState() -> String {
    guard let s = try? String(contentsOfFile: stateFile, encoding: .utf8) else {
        return "running"
    }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return t.isEmpty ? "running" : t
}

// MARK: - Server lifecycle

// Held at module scope so the control timer closure can flip it.
// Single-threaded access via the control timer's serial dispatch queue
// plus the run loop callbacks.
var server: IOSspectServer? = nil

func startServer() {
    if let s = server, s.isListening {
        fputs("startServer: already listening\n", stdout)
        writeState("running")
        return
    }
    do {
        // Rebuild on every start so port/password changes from the app
        // get picked up. TLS cert is cached on disk.
        let s = try IOSspectServer()
        try s.start()
        server = s
        writeState("running")
    } catch {
        fputs("startServer failed: \(error)\n", stderr)
    }
}

func stopServer() {
    if let s = server {
        s.stop()
    }
    server = nil
    writeState("stopped")
}

// MARK: - Control channel
//
// The SwiftUI app drops a command into controlFile. The daemon runs as
// root, the app as mobile, and launchctl from a sandboxed mobile app
// cannot bootout a root-owned service. File polling is the only reliable
// way to drive Start/Stop/Restart from the app on rootless palera1n.

let controlTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
controlTimer.schedule(deadline: .now() + 1, repeating: 1)
controlTimer.setEventHandler {
    guard FileManager.default.fileExists(atPath: controlFile) else { return }
    // Owner check: control commands must come from the iOS app process
    // (mobile uid) or root. Any other uid (a third-party app exploiting
    // the shared dir's 0775 perms to drop "stop" and DoS us) is ignored.
    let attrs = (try? FileManager.default.attributesOfItem(atPath: controlFile)) ?? [:]
    if let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value {
        if owner != 0 && owner != 501 {
            try? FileManager.default.removeItem(atPath: controlFile)
            fputs("control: ignoring command from uid \(owner)\n", stderr)
            return
        }
    }
    guard let raw = try? String(contentsOfFile: controlFile, encoding: .utf8) else { return }
    try? FileManager.default.removeItem(atPath: controlFile)
    let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    fputs("control: received '\(cmd)'\n", stdout)
    switch cmd {
    case "restart":
        fputs("control: exit(0); launchd KeepAlive will restart us\n", stdout)
        exit(0)
    case "stop":
        stopServer()
    case "start":
        startServer()
    default:
        break
    }
}
controlTimer.resume()

// MARK: - Boot

if desiredState() == "stopped" {
    fputs("state: stopped on disk, not auto-starting listener\n", stdout)
    writeState("stopped")
    CFRunLoopRun()
} else {
    startServer()
    if server == nil {
        // Couldn't start (TLS, port bind, etc.). Surface the failure but
        // stay alive so the user can hit Restart from the app. Exiting
        // would trigger an immediate launchd KeepAlive crashloop.
        fputs("FATAL during start; staying alive on run loop\n", stderr)
    }
    CFRunLoopRun()
}
