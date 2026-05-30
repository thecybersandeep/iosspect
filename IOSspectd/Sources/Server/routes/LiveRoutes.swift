// LiveRoutes.swift - device-wide live state + per-app actions.
//   /processes              sysctl kern.proc.all + proc_pidinfo, with
//                           bundle-id attribution via Info.plist lookup
//   /connections            netstat -an parse (depends on network-cmds)
//   /exec                   POST { command, timeoutSec? }, spawns
//                           /bin/sh -c via ShellRunner.sh
//   /logcat                 polling read from the LogcatStreamer ring
//                           buffer (tailing launchd.log)
//   /actions/clear          rm -rf the data container's contents
//   /actions/pull-apk       streaming IPA download (see AppRoutes /apk)
import Foundation

func liveRoutes(router: Router) {

    router.get("/api/live/processes") { req, ctx in
        let pkgFilter = (req.query["pkg"] ?? "").trimmingCharacters(in: .whitespaces)
        let procs = ProcessReader.list()
        // The web UI uses the optional `packages` array to mark which
        // apps are running. On iOS most user processes are launched
        // from /var/containers/Bundle/Application/<UUID>/<Name>.app/<bin>;
        // we resolve those to a bundle id by reading the .app/Info.plist
        // once per .app path and caching.
        let pkgFor = bundleIdResolver()
        let mapped = procs.map { p -> [String: Any] in
            var pkgs: [String] = []
            if let bid = pkgFor(p.cmdline) { pkgs.append(bid) }
            return [
                "pid"      : p.pid,
                "ppid"     : p.ppid,
                "uid"      : p.uid,
                "name"     : p.name,
                "cmdline"  : p.cmdline,
                "state"    : p.state,
                "threads"  : p.threads,
                "rssKb"    : p.rssKb,
                "packages" : pkgs
            ]
        }
        let filtered: [[String: Any]]
        if pkgFilter.isEmpty {
            filtered = mapped
        } else {
            filtered = mapped.filter { row in
                guard let pkgs = row["packages"] as? [String] else { return false }
                return pkgs.contains(pkgFilter)
            }
        }
        return ctx.json([
            "processes" : filtered,
            "total"     : filtered.count
        ])
    }

    router.get("/api/live/connections") { _, ctx in
        let conns = NetReader.list()
        let rows = conns.map { c -> [String: Any] in [
            "proto"      : c.proto,
            "localAddr"  : c.localAddr,
            "remoteAddr" : c.remoteAddr,
            "state"      : c.state,
            "uid"        : c.uid,
            "inode"      : c.inode
        ] }
        return ctx.json(["connections": rows, "total": rows.count])
    }

    router.post("/api/live/exec") { req, ctx in
        // Enforce JSON content type so a SameSite-evading text/plain
        // form post cannot smuggle a shell command.
        let ct = req.headers["Content-Type"] ?? ""
        guard ct.lowercased().hasPrefix("application/json") else {
            return ctx.json(["error": "expected JSON body"], status: 415)
        }
        guard let body = req.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let cmd  = json["command"] as? String, !cmd.isEmpty else {
            return ctx.json(["error": "POST body must be JSON {\"command\": \"...\"}"], status: 400)
        }
        let timeout = (json["timeoutSec"] as? Double) ?? 10.0
        let r = ShellRunner.sh(cmd, timeoutSec: timeout)
        return ctx.json([
            "stdout"   : r.stdout,
            "stderr"   : r.stderr,
            "code"     : r.code,
            "timedOut" : r.timedOut
        ])
    }

    // Polling-based log tail. The daemon's LogcatStreamer keeps a ring
    // buffer of the last ~2K lines fed by `log stream`. UI hits this
    // every second-ish with the previously-returned cursor.
    router.get("/api/live/logcat") { req, ctx in
        let started = LogcatStreamer.shared.startIfNeeded()
        let from   = Int64(req.query["from"] ?? "0") ?? 0
        let limit  = Int(req.query["limit"] ?? "500") ?? 500
        let filter = req.query["filter"]
        let pidStr = req.query["pid"] ?? "0"
        let pidI   = Int32(pidStr) ?? 0
        let (lines, nextFrom) = LogcatStreamer.shared.read(
            from: from, limit: limit, filter: filter, pid: pidI
        )
        return ctx.json([
            "lines"    : lines.map { ["seq": $0.seq, "line": $0.line] },
            "nextFrom" : nextFrom,
            "running"  : started,
            "buffered" : LogcatStreamer.shared.bufferedCount()
        ])
    }

    router.post("/api/apps/{pkg}/actions/clear") { req, ctx in
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg"], status: 400)
        }
        return ctx.json(actionResultJSON(AppActions.clearData(bundleId: pkg)))
    }
    router.post("/api/apps/{pkg}/actions/pull-apk") { req, ctx in
        // The web UI's pull-APK button actually triggers a direct GET to
        // /api/apps/{pkg}/apk (the streaming download), so this POST is
        // only hit by older clients. Mirror the same payload anyway.
        guard let pkg = Sanitize.extractPkg(fromPath: req.path) else {
            return ctx.json(["error": "bad pkg"], status: 400)
        }
        guard let probe = AppActions.pullIPA(bundleId: pkg) else {
            return ctx.json(["ok": false, "error": "bundle not found"], status: 404)
        }
        // Only asked to confirm the action works. Drop the staged
        // .ipa here; the user-facing download path is the GET.
        try? FileManager.default.removeItem(at: probe)
        return ctx.json(["ok": true, "output": "use GET /api/apps/\(pkg)/apk to download"])
    }
}

private func actionResultJSON(_ r: AppActions.Result) -> [String: Any] {
    var out: [String: Any] = ["ok": r.ok, "output": r.output]
    if let e = r.error { out["error"] = e }
    return out
}

// MARK: - Bundle ID resolver
//
// Closure returns a memoised lookup: process path -> bundle id (or nil
// for system processes that aren't inside a *.app). The resolver caches
// across all calls inside one /processes request, reading each .app's
// Info.plist at most once.
private func bundleIdResolver() -> (String) -> String? {
    var cache: [String: String?] = [:]
    return { (procPath: String) -> String? in
        // Walk up until we find a *.app directory in the path.
        // /var/containers/Bundle/Application/<UUID>/Foo.app/Foo  -> Foo.app
        // /var/jb/Applications/Foo.app/Foo                       -> Foo.app
        // /var/jb/usr/local/bin/iosspectd                        -> no .app
        var dir = procPath
        var appDir: String? = nil
        while !dir.isEmpty, dir != "/" {
            if dir.hasSuffix(".app") { appDir = dir; break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        guard let app = appDir else { return nil }
        if let cached = cache[app] { return cached }
        let plistPath = "\(app)/Info.plist"
        let bid = (NSDictionary(contentsOfFile: plistPath) as? [String: Any])?["CFBundleIdentifier"] as? String
        cache[app] = bid
        return bid
    }
}
