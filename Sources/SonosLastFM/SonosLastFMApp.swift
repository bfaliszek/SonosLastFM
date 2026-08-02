import SwiftUI

@main
struct SonosLastFMApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("SonosLastFM", systemImage: model.isRunning ? "music.note.list" : "music.note") {
            MenuView(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("SonosLastFM Settings", id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 660, height: 680)
    }
}

private struct MenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SonosLastFM").font(.headline)
            if let track = model.currentTrack {
                Text(track.title).font(.headline)
                Text(track.artist).foregroundStyle(.secondary)
            } else {
                Text(model.status).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Scrobbling enabled", isOn: $model.isRunning)
                .toggleStyle(.switch)
                .onChange(of: model.isRunning) { enabled in enabled ? model.start() : model.stop() }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.largeTitle.bold())
                    Text("Connect Sonos and Last.fm, then customize how SonosLastFM works.")
                        .foregroundStyle(.secondary)
                }

                SettingsCard(title: "Sonos Connection", systemImage: "hifispeaker") {
                    SettingsField("Sonos Key (OAuth Client ID)") {
                        TextField("Enter your Sonos Key", text: $sonosClientID)
                    }
                    SettingsField("Sonos Secret (OAuth Client Secret)") {
                        SecureField("Enter your Sonos Secret", text: $sonosClientSecret)
                    }
                    SettingsField("Sonos Refresh Token") {
                        SecureField("Enter your Sonos Refresh Token", text: $sonosRefreshToken)
                    }
                Text("Enter the Key and Secret from Client Credentials — not the integration header's “Your Client ID”.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(isTestingSonos ? "Testing Sonos…" : "Test Sonos connection") {
                    isTestingSonos = true
                    model.save(AppSettings(sonosClientID: sonosClientID, sonosClientSecret: sonosClientSecret, sonosRefreshToken: sonosRefreshToken, lastFMKey: lastFMKey, lastFMSecret: lastFMSecret, lastFMSession: lastFMSession))
                    Task { await model.testSonosConnection(); isTestingSonos = false }
                }
                .disabled(isTestingSonos || sonosClientID.isEmpty || sonosClientSecret.isEmpty || sonosRefreshToken.isEmpty)
                if model.status.contains("Sonos") {
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                }

                SettingsCard(title: "Mac Media Keys", systemImage: "keyboard") {
                Toggle("Use Mac media keys to control Sonos", isOn: $model.mediaKeysEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: model.mediaKeysEnabled) { enabled in model.setMediaKeys(enabled: enabled) }
                Text("Requires Accessibility access. Play/Pause pauses or resumes, and Previous/Next skip tracks in the last Sonos group controlled.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Open Accessibility Settings", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                Text("After granting access, return here and enable the switch again.")
                    .font(.caption).foregroundStyle(.secondary)
                }

                SettingsCard(title: "Startup", systemImage: "power") {
                Toggle("Launch SonosLastFM when you log in", isOn: $model.launchAtLoginEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: model.launchAtLoginEnabled) { enabled in model.setLaunchAtLogin(enabled: enabled) }
                Text("macOS may ask you to approve this app as a login item.")
                    .font(.caption).foregroundStyle(.secondary)
                }

                SettingsCard(title: "Last.fm Connection", systemImage: "waveform") {
                    SettingsField("Last.fm API Key") {
                        TextField("Enter your Last.fm API Key", text: $lastFMKey)
                    }
                    SettingsField("Last.fm Shared Secret") {
                        SecureField("Enter your Last.fm Shared Secret", text: $lastFMSecret)
                    }
                    SettingsField("Last.fm Session Key") {
                        SecureField("Created automatically after connecting", text: $lastFMSession)
                    }
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

                SettingsCard(title: "About", systemImage: "info.circle") {
                    HStack {
                        Text("Current version")
                        Spacer()
                        Text(AppVersion.current)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Check GitHub for updates every hour", isOn: $model.updateChecksEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: model.updateChecksEnabled) { enabled in model.setUpdateChecks(enabled: enabled) }
                    Text("When a newer GitHub release is available, SonosLastFM will offer to open its download page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Reload") { load() }
                    Spacer()
                    Button("Save Changes") { save() }
                        .buttonStyle(.borderedProminent)
                }

                if !model.status.contains("Sonos") {
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 620)
        .onAppear { load() }
    }

    private func save() {
        model.save(AppSettings(sonosClientID: sonosClientID, sonosClientSecret: sonosClientSecret, sonosRefreshToken: sonosRefreshToken, lastFMKey: lastFMKey, lastFMSecret: lastFMSecret, lastFMSession: lastFMSession))
    }

    private func load() {
        let s = model.settings
        sonosClientID = s.sonosClientID; sonosClientSecret = s.sonosClientSecret
        sonosRefreshToken = s.sonosRefreshToken
        lastFMKey = s.lastFMKey; lastFMSecret = s.lastFMSecret; lastFMSession = s.lastFMSession
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SettingsField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.medium))
            content.textFieldStyle(.roundedBorder)
        }
    }
}
