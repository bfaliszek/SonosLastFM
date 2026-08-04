import Foundation
import SwiftUI
import ServiceManagement
import AppKit

struct AppSettings: Codable, Equatable {
    var sonosClientID = ""
    var sonosClientSecret = ""
    var sonosRefreshToken = ""
    var sonosGroupID: String?
    var lastFMKey = ""
    var lastFMSecret = ""
    var lastFMSession = ""
}

struct Track: Hashable {
    let title: String
    let artist: String
    let album: String?
    let duration: Int?
}

struct SonosGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let playbackState: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var currentTrack: Track?
    @Published var status = "Open Settings to connect your accounts."
    @Published var isRunning = UserDefaults.standard.bool(forKey: "scrobblingEnabled")
    @Published var mediaKeysEnabled = UserDefaults.standard.bool(forKey: "mediaKeysEnabled")
    @Published var launchAtLoginEnabled = false
    @Published var updateChecksEnabled = UserDefaults.standard.object(forKey: "updateChecksEnabled") as? Bool ?? true
    @Published var sonosGroups: [SonosGroup] = []
    @Published var isLoadingSonosGroups = false

    private let store = SettingsStore()
    private let mediaKeyController = MediaKeyController()
    private var timer: Timer?
    private var updateTimer: Timer?
    private var updateCheckInFlight = false
    private var startedAt: Date?
    private var submitted = Set<String>()
    private var sonosToken: SonosToken?
    private var lastMediaKeyGroupID: String?
    private var mediaKeyCommandInFlight = false
    private var lastMediaKeyCommandAt = Date.distantPast

    var settings: AppSettings { store.load() }
    var isConfigured: Bool {
        let s = settings
        return !s.sonosClientID.isEmpty && !s.sonosClientSecret.isEmpty && !s.sonosRefreshToken.isEmpty && !s.lastFMKey.isEmpty && !s.lastFMSecret.isEmpty && !s.lastFMSession.isEmpty
    }

    init() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        if mediaKeysEnabled { enableMediaKeys() }
        if updateChecksEnabled { startUpdateChecks() }
    }

    func save(_ settings: AppSettings) {
        store.save(settings.trimmed)
        status = isConfigured ? "Ready — enable scrobbling." : "Enter all required API credentials."
    }

    func startIfEnabled() { if isRunning { start() } }
    func start() {
        guard isConfigured else { status = "Missing API configuration."; isRunning = false; return }
        UserDefaults.standard.set(true, forKey: "scrobblingEnabled")
        timer?.invalidate()
        Task { await pollNow() }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { await self?.pollNow() }
        }
        status = "Listening to Sonos…"
    }

    func stop() { timer?.invalidate(); timer = nil; UserDefaults.standard.set(false, forKey: "scrobblingEnabled"); status = "Paused." }

    func setMediaKeys(enabled: Bool) {
        mediaKeysEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "mediaKeysEnabled")
        enabled ? enableMediaKeys() : mediaKeyController.stop()
    }

    func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            status = launchAtLoginEnabled ? "Launch at login enabled." : "Launch at login disabled."
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            status = "Could not update launch at login: \(error.localizedDescription)"
        }
    }

    func setUpdateChecks(enabled: Bool) {
        updateChecksEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "updateChecksEnabled")
        if enabled {
            startUpdateChecks()
        } else {
            updateTimer?.invalidate()
            updateTimer = nil
        }
    }

    private func startUpdateChecks() {
        updateTimer?.invalidate()
        Task { await checkForUpdates() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { await self?.checkForUpdates() }
        }
    }

    private func checkForUpdates() async {
        guard !updateCheckInFlight else { return }
        updateCheckInFlight = true
        defer { updateCheckInFlight = false }
        do {
            guard let release = try await GitHubReleaseClient().newerRelease(than: AppVersion.current) else { return }
            let notificationKey = "lastUpdateNotificationTag"
            guard UserDefaults.standard.string(forKey: notificationKey) != release.tagName else { return }
            UserDefaults.standard.set(release.tagName, forKey: notificationKey)
            presentUpdateAlert(release)
        } catch {
            // Update checks are silent: a temporary network or GitHub error must not interrupt scrobbling.
        }
    }

    private func presentUpdateAlert(_ release: AppRelease) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "A new version of SonosLastFM is available"
        alert.informativeText = "Version \(release.tagName) is available. You are using version \(AppVersion.current)."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func enableMediaKeys() {
        let enabled = mediaKeyController.start(
            onPrevious: { [weak self] in Task { await self?.skipSonosTrack(next: false) } },
            onPlayPause: { [weak self] in Task { await self?.toggleSonosPlayback() } },
            onNext: { [weak self] in Task { await self?.skipSonosTrack(next: true) } }
        )
        if !enabled {
            mediaKeysEnabled = false
            UserDefaults.standard.set(false, forKey: "mediaKeysEnabled")
            status = "Allow Accessibility access in System Settings to use the global media keys."
        }
    }

    private func toggleSonosPlayback() async {
        guard !mediaKeyCommandInFlight, Date().timeIntervalSince(lastMediaKeyCommandAt) > 0.75 else { return }
        mediaKeyCommandInFlight = true
        lastMediaKeyCommandAt = Date()
        defer { mediaKeyCommandInFlight = false }
        let sonos = settings
        guard !sonos.sonosClientID.isEmpty, !sonos.sonosClientSecret.isEmpty, !sonos.sonosRefreshToken.isEmpty else {
            status = "Configure Sonos before using the media key."
            return
        }
        do {
            let token = try await validSonosToken()
            let result = try await SonosClient(accessToken: token.accessToken).togglePlayback(preferredGroupID: settings.sonosGroupID ?? lastMediaKeyGroupID)
            lastMediaKeyGroupID = result.groupID
            status = result.isPlaying ? "Sonos playing" : "Sonos paused"
        } catch {
            status = "Sonos media key failed: \(error.localizedDescription)"
        }
    }

    private func skipSonosTrack(next: Bool) async {
        guard !mediaKeyCommandInFlight, Date().timeIntervalSince(lastMediaKeyCommandAt) > 0.75 else { return }
        mediaKeyCommandInFlight = true
        lastMediaKeyCommandAt = Date()
        defer { mediaKeyCommandInFlight = false }
        let sonos = settings
        guard !sonos.sonosClientID.isEmpty, !sonos.sonosClientSecret.isEmpty, !sonos.sonosRefreshToken.isEmpty else {
            status = "Configure Sonos before using the media keys."
            return
        }
        do {
            let token = try await validSonosToken()
            lastMediaKeyGroupID = try await SonosClient(accessToken: token.accessToken).skipTrack(next: next, preferredGroupID: settings.sonosGroupID ?? lastMediaKeyGroupID)
            status = next ? "Skipped to next Sonos track" : "Skipped to previous Sonos track"
        } catch {
            status = "Sonos media key failed: \(error.localizedDescription)"
        }
    }

    func connectLastFM(apiKey: String, sharedSecret: String) async -> String? {
        guard !apiKey.isEmpty, !sharedSecret.isEmpty else {
            status = "Enter the Last.fm API Key and Shared Secret."
            return nil
        }
        do {
            status = "Opening the Last.fm authorization page…"
            let sessionKey = try await LastFMAuth(apiKey: apiKey, sharedSecret: sharedSecret).authorize()
            status = "Last.fm connected ✓"
            return sessionKey
        } catch {
            status = "Last.fm connection failed: \(error.localizedDescription)"
            return nil
        }
    }

    func testSonosConnection() async {
        let sonos = settings
        guard !sonos.sonosClientID.isEmpty, !sonos.sonosClientSecret.isEmpty, !sonos.sonosRefreshToken.isEmpty else {
            status = "Save all Sonos credentials first."
            return
        }
        do {
            _ = try await validSonosToken()
            status = "Sonos OAuth is working correctly."
        } catch {
            status = "Sonos test failed: \(error.localizedDescription)"
        }
    }

    func loadSonosGroups() async {
        guard !isLoadingSonosGroups else { return }
        let sonos = settings
        guard !sonos.sonosClientID.isEmpty, !sonos.sonosClientSecret.isEmpty, !sonos.sonosRefreshToken.isEmpty else {
            status = "Save all Sonos credentials first."
            return
        }
        isLoadingSonosGroups = true
        defer { isLoadingSonosGroups = false }
        do {
            let token = try await validSonosToken()
            sonosGroups = try await SonosClient(accessToken: token.accessToken).groups()
            status = sonosGroups.isEmpty ? "No Sonos groups were found." : "Found \(sonosGroups.count) Sonos group(s)."
        } catch {
            status = "Could not load Sonos groups: \(error.localizedDescription)"
        }
    }

    func selectSonosGroup(_ groupID: String?) {
        var updated = settings
        updated.sonosGroupID = groupID
        store.save(updated.trimmed)
        lastMediaKeyGroupID = groupID
        currentTrack = nil
        startedAt = nil
        if isRunning { Task { await pollNow() } }
    }

    func pollNow() async {
        guard isConfigured else { return }
        do {
            let token = try await validSonosToken()
            let track = try await SonosClient(accessToken: token.accessToken).currentlyPlaying(preferredGroupID: settings.sonosGroupID)
            guard let track else {
                // Reset the listening session: a resumed track must not inherit time
                // that passed while Sonos was paused or idle.
                currentTrack = nil
                startedAt = nil
                status = "Sonos is not playing anything."
                return
            }
            if track != currentTrack { currentTrack = track; startedAt = Date(); status = "Playback detected"; try await LastFMClient(settings: settings).updateNowPlaying(track) }
            await scrobbleIfDue(track)
        } catch { status = "Error: \(error.localizedDescription)" }
    }

    private func scrobbleIfDue(_ track: Track) async {
        guard let startedAt else { return }
        let required = min(240.0, max(30.0, Double(track.duration ?? 60) / 2))
        guard Date().timeIntervalSince(startedAt) >= required else { return }
        let id = "\(track.artist)|\(track.title)|\(Int(startedAt.timeIntervalSince1970))"
        guard submitted.insert(id).inserted else { return }
        do { try await LastFMClient(settings: settings).scrobble(track, timestamp: Int(startedAt.timeIntervalSince1970)); status = "Scrobble sent ✓" }
        catch { submitted.remove(id); status = "Not sent: \(error.localizedDescription)" }
    }

    private func validSonosToken() async throws -> SonosToken {
        if let sonosToken, sonosToken.expiresAt > Date().addingTimeInterval(60) { return sonosToken }
        let configured = settings
        let token = try await SonosAuth(settings: configured).refreshToken()
        if token.refreshToken != configured.sonosRefreshToken {
            var updated = configured
            updated.sonosRefreshToken = token.refreshToken
            store.save(updated)
        }
        sonosToken = token
        return token
    }
}

enum AppVersion {
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
}

private extension AppSettings {
    var trimmed: AppSettings {
        AppSettings(
            sonosClientID: sonosClientID.trimmingCharacters(in: .whitespacesAndNewlines),
            sonosClientSecret: sonosClientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            sonosRefreshToken: sonosRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines),
            sonosGroupID: sonosGroupID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            lastFMKey: lastFMKey.trimmingCharacters(in: .whitespacesAndNewlines),
            lastFMSecret: lastFMSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            lastFMSession: lastFMSession.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
