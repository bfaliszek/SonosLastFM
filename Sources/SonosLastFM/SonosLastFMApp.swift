import SwiftUI

@main
struct SonosLastFMApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Sonos → Last.fm", systemImage: model.isRunning ? "music.note.list" : "music.note") {
            MenuView(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Sonos → Last.fm Settings", id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 520, height: 410)
    }
}

private struct MenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sonos → Last.fm").font(.headline)
            if let track = model.currentTrack {
                Text(track.title).font(.headline)
                Text(track.artist).foregroundStyle(.secondary)
            } else {
                Text(model.status).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Scrobbling enabled", isOn: $model.isRunning)
                .onChange(of: model.isRunning) { enabled in enabled ? model.start() : model.stop() }
            Button("Check now") { Task { await model.pollNow() } }
                .disabled(!model.isConfigured)
            Button("Settings…") { openWindow(id: "settings") }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding()
        .frame(width: 300)
        .task { model.startIfEnabled() }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var sonosClientID = ""
    @State private var sonosClientSecret = ""
    @State private var sonosRefreshToken = ""
    @State private var lastFMKey = ""
    @State private var lastFMSecret = ""
    @State private var lastFMSession = ""
    @State private var isConnectingLastFM = false
    @State private var isTestingSonos = false

    var body: some View {
        Form {
            Section("Sonos Connection") {
                TextField("Sonos Key (OAuth Client ID)", text: $sonosClientID)
                SecureField("Sonos Secret (OAuth Client Secret)", text: $sonosClientSecret)
                SecureField("Sonos Refresh Token", text: $sonosRefreshToken)
                Text("Enter the Key and Secret from Client Credentials — not the integration header's “Your Client ID”.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(isTestingSonos ? "Testing Sonos…" : "Test Sonos connection") {
                    isTestingSonos = true
                    model.save(AppSettings(sonosClientID: sonosClientID, sonosClientSecret: sonosClientSecret, sonosRefreshToken: sonosRefreshToken, lastFMKey: lastFMKey, lastFMSecret: lastFMSecret, lastFMSession: lastFMSession))
                    Task { await model.testSonosConnection(); isTestingSonos = false }
                }
                .disabled(isTestingSonos || sonosClientID.isEmpty || sonosClientSecret.isEmpty || sonosRefreshToken.isEmpty)
            }

            Section("Mac Media Keys") {
                Toggle("Use Mac Play/Pause key to control Sonos", isOn: $model.mediaKeysEnabled)
                    .onChange(of: model.mediaKeysEnabled) { enabled in model.setMediaKeys(enabled: enabled) }
                Text("Requires Accessibility access. While enabled, the global Play/Pause key pauses or resumes the last Sonos group it controlled.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Open Accessibility Settings", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                Text("After granting access, return here and enable the switch again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch Sonos → Last.fm when you log in", isOn: $model.launchAtLoginEnabled)
                    .onChange(of: model.launchAtLoginEnabled) { enabled in model.setLaunchAtLogin(enabled: enabled) }
                Text("macOS may ask you to approve this app as a login item.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Last.fm") {
                TextField("Last.fm API Key", text: $lastFMKey)
                SecureField("Last.fm Shared Secret", text: $lastFMSecret)
                SecureField("Last.fm Session Key", text: $lastFMSession)
                Button(isConnectingLastFM ? "Waiting for browser approval…" : "Connect Last.fm") {
                    isConnectingLastFM = true
                    Task {
                        if let sessionKey = await model.connectLastFM(apiKey: lastFMKey, sharedSecret: lastFMSecret) {
                            lastFMSession = sessionKey
                        }
                        isConnectingLastFM = false
                    }
                }
                .disabled(isConnectingLastFM || lastFMKey.isEmpty || lastFMSecret.isEmpty)
                Text("After browser approval, the Session Key will be filled in automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Reload") { load() }
                Spacer()
                Button("Save") { model.save(AppSettings(sonosClientID: sonosClientID, sonosClientSecret: sonosClientSecret, sonosRefreshToken: sonosRefreshToken, lastFMKey: lastFMKey, lastFMSecret: lastFMSecret, lastFMSession: lastFMSession)) }
                    .buttonStyle(.borderedProminent)
            }
            if model.status.contains("Sonos") {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(width: 520)
        .onAppear { load() }
    }

    private func load() {
        let s = model.settings
        sonosClientID = s.sonosClientID; sonosClientSecret = s.sonosClientSecret
        sonosRefreshToken = s.sonosRefreshToken
        lastFMKey = s.lastFMKey; lastFMSecret = s.lastFMSecret; lastFMSession = s.lastFMSession
    }
}
