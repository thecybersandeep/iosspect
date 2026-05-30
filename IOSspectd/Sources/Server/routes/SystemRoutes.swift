// SystemRoutes.swift - /api/status.
import Foundation

func systemRoutes(router: Router) {
    router.get("/api/status") { _, ctx in
        let dev = DeviceInfo()
        return ctx.json([
            "app": "IOSspect",
            "version": "0.1.0",
            "buildType": "debug",
            "rootAvailable": dev.jailbroken,
            "shellUser": dev.user,
            "device": [
                "manufacturer": "Apple",
                "model": dev.model,
                "androidVersion": dev.iosVersion,  // key kept for UI parity
                "sdk": dev.sdk,
                "abi": dev.abi
            ]
        ])
    }
}

private struct DeviceInfo {
    let jailbroken: Bool
    let user: String
    let model: String
    let iosVersion: String
    let sdk: Int
    let abi: String

    init() {
        // Daemon already runs as root via launchd. Use the uid/gid we
        // booted with instead of probing for "jailbreak".
        self.jailbroken = getuid() == 0
        self.user = jailbroken ? "root" : "mobile"

        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        self.model = String(cString: bytes)

        // Resolved by OSVersion (SystemVersion.plist with sysctl fallback).
        self.iosVersion = OSVersion.raw
        self.sdk = OSVersion.major
        self.abi = "arm64"
    }
}
