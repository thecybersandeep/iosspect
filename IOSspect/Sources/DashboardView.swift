// DashboardView.swift - the screen you see when you tap the
// home-screen icon. Status pill, URL box, fingerprint, password, port,
// start/stop.

import SwiftUI

struct DashboardView: View {

    @StateObject private var server = ServerControl.shared
    @State private var portText = "\(Settings.shared.port)"
    @State private var copied: CopyTarget? = nil
    // Persists across app launches via UserDefaults under "appTheme".
    // "dark" / "light" only; we don't expose "system" to keep the
    // toggle a single tap.
    @AppStorage("appTheme") private var appTheme: String = "dark"

    enum CopyTarget { case url, fingerprint, password }

    private var isDark: Bool { appTheme != "light" }

    var body: some View {
        ZStack {
            // Background tracks the theme too, otherwise toggling .light
            // leaves a black canvas behind every card.
            (isDark
                ? Color(red: 0x07/255.0, green: 0x08/255.0, blue: 0x0B/255.0)
                : Color(red: 0xF5/255.0, green: 0xF6/255.0, blue: 0xF8/255.0))
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statusCard
                    portCard
                    passwordCard
                    diagnosticsFooter
                }
                .padding(20)
            }
        }
        .preferredColorScheme(isDark ? .dark : .light)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(accent)
            Text("IOS").bold().font(.system(size: 22)).foregroundColor(isDark ? .white : .black)
            + Text("spect").font(.system(size: 22)).foregroundColor(.gray)
            Spacer()
            Button {
                appTheme = isDark ? "light" : "dark"
            } label: {
                Image(systemName: isDark ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.gray)
            }
            .accessibilityLabel(isDark ? "Switch to light mode" : "Switch to dark mode")
        }
        .padding(.bottom, 4)
    }

    // MARK: - Status card (URL / fingerprint / start / stop)

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Headline + dot
            HStack(spacing: 8) {
                Circle().frame(width: 8, height: 8).foregroundColor(server.isRunning ? accent : .gray)
                Text(server.isRunning ? "OPEN IN BROWSER" : "SERVER STOPPED")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(server.isRunning ? accent : .gray)
                    .kerning(0.8)
            }
            // Big URL box
            if server.isRunning, let url = server.url {
                copyRow(label: url, target: .url)
                Text("Wired up. ").font(.system(size: 26, weight: .bold)).foregroundColor(primaryText)
                    + Text("Inspect.").font(.system(size: 26, weight: .bold)).foregroundColor(accent)
                Text("Server is up. Open the URL in any browser. Sign in with the password below.")
                    .font(.system(size: 13)).foregroundColor(.gray)
            } else {
                Text("Tap Start to bring the HTTP listener back up. The daemon stays loaded as root in the background.")
                    .font(.system(size: 13)).foregroundColor(.gray)
            }
            HStack(spacing: 10) {
                if server.isRunning {
                    Button {
                        server.stop()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                            Text("Stop server")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color(red: 0xE5/255, green: 0x3E/255, blue: 0x3E/255))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Button {
                        server.restart()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("Restart")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .foregroundColor(outlineLabel)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.35), lineWidth: 1))
                    }
                } else {
                    Button {
                        server.start()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("Start server")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(accent)
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                if let err = server.lastError {
                    Text(err).font(.system(size: 12)).foregroundColor(.red).lineLimit(2)
                }
                Spacer()
            }
        }
        .padding(16)
        .background(panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(server.isRunning ? accent.opacity(0.4) : .gray.opacity(0.15), lineWidth: 1))
    }

    // MARK: - Port card

    private var portCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PORT").font(.system(size: 11, weight: .semibold))
                .foregroundColor(accent).kerning(0.8)
            HStack {
                TextField("8008", text: $portText)
                    .keyboardType(.numberPad)
                    .padding(10)
                    .background(inputBg)
                    .foregroundColor(primaryText)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.2), lineWidth: 1))
            }
            Button {
                if let p = Int(portText), (1024...65535).contains(p) {
                    Settings.shared.port = p
                    // Full restart so the daemon re-reads the port from
                    // SharedSettings.load() and rebinds.
                    if server.isRunning { server.restart() }
                }
            } label: {
                Label("Save & restart", systemImage: "checkmark.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .foregroundColor(outlineLabel)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.3), lineWidth: 1))
            }
        }
        .padding(16)
        .background(panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Password card

    private var passwordCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BROWSER PASSWORD").font(.system(size: 11, weight: .semibold))
                .foregroundColor(accent).kerning(0.8)
            copyRow(label: server.password, target: .password, mono: true)
            HStack {
                Button {
                    UIPasteboard.general.string = server.password
                    flash(.password)
                } label: {
                    Label("Copy", systemImage: copied == .password ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .foregroundColor(outlineLabel)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.3), lineWidth: 1))
                }
                Button {
                    server.regeneratePassword()
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .foregroundColor(outlineLabel)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.3), lineWidth: 1))
                }
                Spacer()
            }
        }
        .padding(16)
        .background(panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Diagnostics

    private var diagnosticsFooter: some View {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let os = UIDevice.current.systemVersion
        return HStack(spacing: 4) {
            Text("v\(v) ").foregroundColor(.gray)
            Text("· iOS \(os) ").foregroundColor(.gray)
            Text("· \(server.deviceWord)").foregroundColor(accent)
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func copyRow(label: String, target: CopyTarget, mono: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .semibold, design: mono ? .monospaced : .default))
                .foregroundColor(target == .url ? accent : primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                UIPasteboard.general.string = label
                flash(target)
            } label: {
                Image(systemName: copied == target ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13)).foregroundColor(.gray)
            }
        }
        .padding(12)
        .background(inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.18), lineWidth: 1))
    }

    private func flash(_ which: CopyTarget) {
        copied = which
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copied == which { copied = nil }
        }
    }

    // Accent is identical across themes. The green reads fine on both
    // dark and light panels.
    private let accent = Color(red: 0x10/255.0, green: 0xD6/255.0, blue: 0x89/255.0)

    // Theme tokens. Swap the few colours that flip between themes so
    // the card bodies stay free of isDark ternaries.
    private var panel: Color {
        isDark
            ? Color(red: 0x0E/255.0, green: 0x10/255.0, blue: 0x14/255.0)
            : Color.white
    }
    private var inputBg: Color {
        isDark ? .black : Color(red: 0xEE/255.0, green: 0xEF/255.0, blue: 0xF2/255.0)
    }
    private var primaryText: Color { isDark ? .white : .black }
    /// Outlined-button label colour. Goes black on light so the text
    /// stays visible against the panel.
    private var outlineLabel: Color { isDark ? .white : .black }
}
