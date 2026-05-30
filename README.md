# IOSspect

On-device runtime auditor for jailbroken iOS. Serves an HTTPS dashboard from the phone; you drive it from a browser on the same network or over `127.0.0.1`. Read any installed app's bundle and data container, run SQL against its databases, tail the system log, run a root shell, package the bundle as an `.ipa`.

```
  iPhone (jailbroken, root)           Browser
  +----------------------+            +---------+
  |  IOSspect.app  (UI)  |            |         |
  |     |                |            |         |
  |     v writes plist   |    HTTPS   |  any    |
  |  iosspectd (daemon) -|-----:8008--|  webkit |
  |    HTTPS 0.0.0.0     |            |  / V8   |
  +----------------------+            +---------+
```

## Compatibility

|  |  |
| - | - |
| iOS min | 15.0 |
| iOS max | 26.x |
| Architectures | arm64 |
| Required | jailbreak with root and the `platform-application` entitlement (palera1n rootless, Dopamine, etc.) |

Why jailbreak only: reading another app's `Containers/Data/Application/<UUID>/` is sandbox-blocked on stock iOS. TrollStore alone is not enough; the daemon needs both root and `platform-application` to step past per-container ACLs and to `posix_spawn` arbitrary binaries.

## Install

### Sileo / Zebra

1. Sources tab, `+`, paste `https://thecybersandeep.github.io/iosspect/`
2. Find **IOSspect**, tap **Get**
3. Open the IOSspect icon on the home screen
4. The dashboard shows: URL, cert fingerprint, browser password, **Start server**
5. Open the URL in any browser, accept the self-signed cert once, sign in with the password

The Sileo repo updates on every push to `main` (GitHub Actions publishes `repo/` to `gh-pages`). To upgrade, refresh Sileo sources and tap **Modify > Upgrade**.

### Manual `.deb`

Grab the latest from [Releases](https://github.com/thecybersandeep/iosspect/releases) and `dpkg -i com.iosspect.tool_*.deb` over SSH. Both rootful and rootless variants are built per push.

## What's in it

| Tab | What it shows |
| - | - |
| Files | Walk an app's data container or bundle. Click a file to preview as text, hex, plist, SQLite, or image. KTX snapshots decode via `UIImage`. Recursive grep and per-directory ZIP download. |
| Frameworks | Every Mach-O in the bundle (main binary, `Frameworks/*.dylib`, `*.framework`, `PlugIns/*.appex`). Per-slice arch, symbol-stripped flag, FairPlay encryption flag. Download any slice. |
| Processes | `sysctl kern.proc.all` + `proc_pidinfo` per pid. RSS, threads, state, parent. Each process is mapped to a bundle id when it lives under a `*.app` so the app list dot turns green for running apps. |
| Network | `netstat -an` parse. TCP / UDP, IPv4 / IPv6, local + remote addr, state. |
| Console | Tails `/var/log/com.apple.xpc.launchd/launchd.log` via a polling endpoint. Filter by substring or pid, save buffer to a file. |
| Shell | `posix_spawn /bin/sh -c <command>` as root. PATH is widened to include `/var/jb/usr/bin`, `/var/jb/usr/sbin`, etc., so `id`, `ls`, `ps`, `netstat`, `lsof` all resolve. |
| (App actions) | Download IPA (streams the bundle as `Payload/<App>.app/...` zip; still FairPlay-encrypted for App Store installs). Wipe data container (kills any running processes under the bundle, then `rm -rf` the contents). |

Endpoints all gated by a session cookie issued at `/api/auth/login`. The cookie is `HttpOnly; Secure; SameSite=Strict`.

## Security posture

The daemon runs as root with `no-sandbox` and `platform-application`. The threat model assumes a same-LAN attacker who can reach `https://<phone>:8008`.

* Self-signed TLS cert with the device IP in SAN. Cert regenerates automatically on IP change.
* Cookie auth. Sessions are 24 random bytes, persisted to `/var/mobile/Library/IOSspect/sessions.json` (mode 0600) so daemon restarts don't log the user out. 12-hour TTL.
* Rate limiter: per-IP exponential backoff (max 60s) plus a global counter (20 failures across all IPs in 10 minutes triggers a 10 minute lockout). Both persist to disk so a crash-loop scanner can't reset them.
* All POSTs reject non-JSON bodies (defense against form-based CSRF if `SameSite=Strict` ever weakens).
* All file routes route user input through `Sanitize.safePathUnder` which enforces a path-component boundary, not a prefix match.
* SQLite query route accepts only `SELECT` / `WITH ... SELECT` and explicitly rejects `INSERT|UPDATE|DELETE|DROP|ALTER|ATTACH|DETACH|CREATE|REPLACE|PRAGMA`.
* Per-file Mach-O reads, SQLite stages, and the dir-zip writer all stream via raw POSIX `read`/`write` so the daemon's heap stays small (peaked at ~18 MB while zipping a 131 MB bundle).
* Default bind is `127.0.0.1`. LAN access (`0.0.0.0`) is an opt-in toggle in the iOS app.

## Build (CI)

Push to `main`. The `build` workflow on `ubuntu-latest`:

1. installs Theos via `theos/setup-theos-jailed`
2. pulls the iPhoneOS SDK from `theos/sdks`
3. runs `make package FINALPACKAGE=1` twice (rootful + rootless)
4. uploads both `.deb` files as workflow artifacts
5. on a tag push, attaches them to a GitHub Release

The `publish-repo` workflow drops the produced `.deb` into `repo/debs/`, regenerates `Packages`/`Packages.bz2`/`Packages.gz`/`Release`, force-pushes `repo/` to `gh-pages`. Sileo / Zebra clients see the new version on next refresh.

## Build (locally)

Requires Theos + iOS SDK on Linux or macOS.

```
git clone https://github.com/thecybersandeep/iosspect
cd iosspect
make package FINALPACKAGE=1
# rootless variant:
THEOS_PACKAGE_SCHEME=rootless make clean package FINALPACKAGE=1
```

## Project layout

```
IOSspect/
  Makefile                              Theos root, two subprojects
  control                               deb metadata
  IOSspect/                             SwiftUI .app (home-screen icon)
    Sources/
      AppDelegate.swift, SceneDelegate.swift
      DashboardView.swift               start/stop, URL, fingerprint, password
      ServerControl.swift               talks to the daemon via the control file
      Settings.swift                    shared plist with the daemon
      CryptoUtil.swift                  random password, IPv4 lookup
  IOSspectd/                            Swift daemon (the HTTPS server)
    entitlements.plist
    Sources/
      main.swift                        boot, state file, control timer
      Server/
        IOSspectServer.swift            Network.framework listener + TLS
        TLSManager.swift                self-signed cert + IP-change regen
        Security.swift                  password auth, sessions, rate limit
        Router.swift                    HTTP/1.1 dispatcher with .file streaming
        OSVersion.swift
        routes/
          SystemRoutes.swift
          AppRoutes.swift
          FileRoutes.swift
          PrefsRoutes.swift
          SqliteRoutes.swift
          ManifestRoutes.swift
          LiveRoutes.swift
          AssetRoutes.swift
      Root/                             privileged iOS-specific primitives
        AppDataReader.swift
        FileBrowser.swift
        PlistReader.swift
        SqliteReader.swift              libsqlite3 wrapper
        NativeLibScanner.swift          Mach-O probe (arch, strip, encrypt)
        ProcessReader.swift             sysctl kern.proc.all + proc_pidinfo
        NetReader.swift                 netstat parse
        LogcatStreamer.swift            tail launchd.log into a ring buffer
        ShellRunner.swift               posix_spawn /bin/sh -c
        AppActions.swift                wipe data container, pull IPA
        ZipWriter.swift                 streaming PKZip 2.0 (STORE)
        Sanitize.swift                  input validation, path containment
  layout/                               files installed verbatim
    DEBIAN/postinst                     bootstraps the launchd daemon
    Library/LaunchDaemons/
      com.iosspect.daemon.plist
  repo/                                 GitHub Pages source for the Sileo repo
  layout/usr/share/iosspect/web/        embedded SPA (served by the daemon)
  .github/workflows/
    build.yml                           builds the .deb on Ubuntu
    publish-repo.yml                    ships it to gh-pages
```

## Screenshots

Drop your own screenshots into `screenshots/` if you want them rendered here. The dashboard looks like this from the browser:

```
+-----------------------------------------------------------------------+
| IOSspect      APK Auditor  IPA Auditor  ADB Auditor    jailbroken  o |
+---------------------+--------------------------------------------------+
| Filter apps         | Calculator   com.apple.calculator               |
| [ ] system apps     |                                                  |
| 39 apps . 7 running | Files | Frameworks                               |
|                     |                                                  |
| AppleTV             | Up | /data/data/com.apple.calculator             |
| Be Well        .    |                                                  |
| Books               | folder Documents                                 |
| Calculator     (*)  | folder Library                                   |
| Calendar       .    | folder SystemData                                |
| Clock               | folder tmp                                       |
|                     | file   .com.apple.mobile_container_manager...    |
| [ Live ]            |                                                  |
| Processes           |                                                  |
| Network             |                                                  |
| Console             |                                                  |
| Shell               |                                                  |
|                     |                                                  |
| [|>] [|=] [v] [X]   |                                                  |
+---------------------+--------------------------------------------------+
```

## License

MIT.

---

Built by **[thecybersandeep](https://github.com/thecybersandeep)**.
