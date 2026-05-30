// AppActions.swift - per-app actions exposed in the dashboard.
//
//   clearData         SIGKILL any process under the bundle then rm -rf
//                     the data container's contents
//   pullIPA           zip <bundle> into Payload/<App>.app/ (still
//                     FairPlay-encrypted)

import Foundation
import Darwin

enum AppActions {

    struct Result: Codable {
        let ok: Bool
        let output: String
        let error: String?
    }

    // MARK: - clearData

    static func clearData(bundleId: String) -> Result {
        // Stop first so the app isn't holding handles into the
        // container. proc_pidpath returns `/private`-prefixed canonical
        // paths but FileBrowser returns the non-prefixed form. Strip
        // `/private` from both so the comparison lands.
        if let bundle = FileBrowser.resolveRoot(pkg: bundleId, root: .bundle) {
            let needle = canon(bundle)
            for p in ProcessReader.list() where canon(p.cmdline).hasPrefix(needle) {
                _ = kill(p.pid, SIGKILL)
            }
        }
        guard let dataDir = FileBrowser.resolveRoot(pkg: bundleId, root: .data) else {
            return Result(ok: false, output: "", error: "data container not found")
        }
        let fm = FileManager.default
        var removed = 0
        var failed: [String] = []
        // Wipe contents but keep the container directory itself. Its
        // inode is what the .com.apple.mobile_container_manager metadata
        // points at; replacing the dir would orphan the app.
        if let entries = try? fm.contentsOfDirectory(atPath: dataDir) {
            for e in entries {
                let p = "\(dataDir)/\(e)"
                do { try fm.removeItem(atPath: p); removed += 1 }
                catch { failed.append("\(e): \(error.localizedDescription)") }
            }
        }
        let msg = "removed \(removed) entries from \(dataDir)"
                + (failed.isEmpty ? "" : "; failed: \(failed.joined(separator: ", "))")
        return Result(ok: failed.isEmpty, output: msg,
                      error: failed.isEmpty ? nil : "some entries could not be removed")
    }

    private static func canon(_ p: String) -> String {
        p.hasPrefix("/private") ? String(p.dropFirst(8)) : p
    }

    // MARK: - pullIPA

    /// Builds an IPA-shaped ZIP wrapping the bundle as
    /// Payload/<App>.app/. Writes to a temp file on disk; caller streams
    /// it back and deletes the file when done. Returning a file path
    /// (not Data) keeps peak daemon memory at one source chunk
    /// regardless of bundle size.
    ///
    /// The main binary inside is still FairPlay-encrypted on App Store
    /// installs. Useful for inspection / auditing, not for sideloading.
    static func pullIPA(bundleId: String) -> URL? {
        guard let bundle = FileBrowser.resolveRoot(pkg: bundleId, root: .bundle) else {
            return nil
        }
        let appName = (bundle as NSString).lastPathComponent
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosspect-ipa-\(UUID().uuidString).ipa")
        guard ZipWriter.writeDirectory(root: bundle,
                                        baseLabel: "Payload/\(appName)",
                                        out: out) != nil else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }
}
