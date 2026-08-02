import Foundation
import CommonCrypto
import AppKit

struct SonosToken: Codable { let accessToken: String; let expiresAt: Date; let refreshToken: String }

enum ServiceError: LocalizedError { case missingRefreshToken, response(String), invalidData
    var errorDescription: String? { switch self { case .missingRefreshToken: return "Sonos Refresh Token is missing — complete OAuth authorization."; case .response(let message): return message; case .invalidData: return "Invalid server response." } }
}

struct AppRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft, prerelease
    }
}

struct GitHubReleaseClient {
    func newerRelease(than currentVersion: String) async throws -> AppRelease? {
        guard let current = VersionNumber(currentVersion) else { return nil }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/bfaliszek/SonosLastFM/releases")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SonosLastFM", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServiceError.response("GitHub releases could not be checked.")
        }
        let releases = try JSONDecoder().decode([AppRelease].self, from: data)
        return releases
            .filter { !$0.draft && !$0.prerelease }
            .compactMap { release in VersionNumber(release.tagName).map { ($0, release) } }
            .filter { $0.0 > current }
            .max { $0.0 < $1.0 }?
            .1
    }
}

struct VersionNumber: Comparable {
    let parts: [Int]

    init?(_ string: String) {
        let value = string.hasPrefix("v") || string.hasPrefix("V") ? String(string.dropFirst()) : string
        let core = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
        let parts = core.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty, core.split(separator: ".").count == parts.count else { return nil }
        self.parts = parts
    }

    static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

struct SonosAuth {
    let settings: AppSettings
    func refreshToken() async throws -> SonosToken {
        let refresh = settings.sonosRefreshToken
        guard !refresh.isEmpty else { throw ServiceError.missingRefreshToken }
        var request = URLRequest(url: URL(string: "https://api.sonos.com/login/v3/oauth/access")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(Data("\(settings.sonosClientID):\(settings.sonosClientSecret)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.httpBody = "grant_type=refresh_token&refresh_token=\(refresh.urlEncoded)".data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let jsonMessage = (json?["message"] as? String) ?? (json?["error_description"] as? String) ?? (json?["error"] as? String)
            let responseText = String(data: data, encoding: .utf8).map { String($0.prefix(180)) }
            let details = jsonMessage ?? responseText ?? "no details"
            throw ServiceError.response("Sonos OAuth rejected the token refresh: \(details)")
        }
        let token = try JSONDecoder().decode(OAuthResponse.self, from: data)
        return SonosToken(accessToken: token.access_token, expiresAt: Date().addingTimeInterval(token.expires_in), refreshToken: token.refresh_token)
    }
    private struct OAuthResponse: Codable { let access_token: String; let expires_in: TimeInterval; let refresh_token: String }
}

struct SonosClient {
    let accessToken: String

    func currentlyPlaying() async throws -> Track? {
        let group = try await activeGroup()
        let request = authorizedRequest("https://api.ws.sonos.com/control/api/v1/groups/\(group.id.urlPathEncoded)/playbackMetadata")
        let (data, metadataResponse) = try await URLSession.shared.data(for: request)
        guard (metadataResponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let item = json?["currentItem"] as? [String: Any],
              let track = item["track"] as? [String: Any],
              let title = track["name"] as? String,
              let artist = (track["artist"] as? [String: Any])?["name"] as? String else { return nil }
        let album = (track["album"] as? [String: Any])?["name"] as? String
        return Track(title: title, artist: artist, album: album, duration: track["durationMillis"] as? Int).normalized
    }

    func togglePlayback(preferredGroupID: String?) async throws -> (isPlaying: Bool, groupID: String) {
        let group = try await activeGroup(preferredGroupID: preferredGroupID)
        let shouldPlay = group.playbackState != "PLAYBACK_STATE_PLAYING"
        let action = shouldPlay ? "play" : "pause"
        var request = authorizedRequest("https://api.ws.sonos.com/control/api/v1/groups/\(group.id.urlPathEncoded)/playback/\(action)")
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServiceError.response("Sonos could not \(action) the active group.")
        }
        return (shouldPlay, group.id)
    }

    func skipTrack(next: Bool, preferredGroupID: String?) async throws -> String {
        let group = try await activeGroup(preferredGroupID: preferredGroupID)
        let action = next ? "skipToNextTrack" : "skipToPreviousTrack"
        var request = authorizedRequest("https://api.ws.sonos.com/control/api/v1/groups/\(group.id.urlPathEncoded)/playback/\(action)")
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ServiceError.response("Sonos could not skip the active group’s track.")
        }
        return group.id
    }

    private func activeGroup(preferredGroupID: String? = nil) async throws -> (id: String, playbackState: String) {
        var request = URLRequest(url: URL(string: "https://api.ws.sonos.com/control/api/v1/households")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (households, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.response("Unable to read Sonos households.") }
        guard let householdList = try JSONSerialization.jsonObject(with: households) as? [String: Any],
              let household = (householdList["households"] as? [[String: Any]])?.first,
              let id = household["id"] as? String else { throw ServiceError.invalidData }
        request.url = URL(string: "https://api.ws.sonos.com/control/api/v1/households/\(id.urlPathEncoded)/groups")!
        let (groups, _) = try await URLSession.shared.data(for: request)
        guard let groupsBody = try JSONSerialization.jsonObject(with: groups) as? [String: Any],
              let availableGroups = groupsBody["groups"] as? [[String: Any]],
              let group = availableGroups.first(where: { ($0["id"] as? String) == preferredGroupID })
                  ?? availableGroups.first(where: { ($0["playbackState"] as? String) == "PLAYBACK_STATE_PLAYING" })
                  ?? availableGroups.first(where: { ($0["playbackState"] as? String) == "PLAYBACK_STATE_PAUSED" })
                  ?? availableGroups.first,
              let groupID = group["id"] as? String else { throw ServiceError.response("No Sonos group is available.") }
        return (groupID, group["playbackState"] as? String ?? "PLAYBACK_STATE_IDLE")
    }

    private func authorizedRequest(_ address: String) -> URLRequest {
        var request = URLRequest(url: URL(string: address)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}

struct LastFMClient {
    let settings: AppSettings
    func updateNowPlaying(_ track: Track) async throws { try await send("track.updateNowPlaying", track: track, timestamp: nil) }
    func scrobble(_ track: Track, timestamp: Int) async throws { try await send("track.scrobble", track: track, timestamp: timestamp) }
    private func send(_ method: String, track: Track, timestamp: Int?) async throws {
        var params = ["method": method, "api_key": settings.lastFMKey, "sk": settings.lastFMSession, "artist": track.artist, "track": track.title]
        if let album = track.album, !album.isEmpty { params["album"] = album }
        if let timestamp { params["timestamp"] = String(timestamp) }
        params["api_sig"] = signature(params)
        params["format"] = "json"
        var request = URLRequest(url: URL(string: "https://ws.audioscrobbler.com/2.0/")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("SonosLastFM/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = params.map { "\($0.key.urlEncoded)=\($0.value.urlEncoded)" }.sorted().joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.response("Last.fm returned an HTTP error.") }
        if let body = try JSONSerialization.jsonObject(with: data) as? [String: Any], let message = body["message"] as? String { throw ServiceError.response("Last.fm: \(message)") }
    }
    private func signature(_ params: [String: String]) -> String { MD5.hex(params.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + settings.lastFMSecret) }
}

struct LastFMAuth {
    let apiKey: String
    let sharedSecret: String

    func authorize() async throws -> String {
        let tokenData = try await request(method: "auth.getToken")
        guard let token = (try JSONSerialization.jsonObject(with: tokenData) as? [String: Any])?["token"] as? String else { throw ServiceError.invalidData }
        guard let url = URL(string: "https://www.last.fm/api/auth/?api_key=\(apiKey.urlEncoded)&token=\(token.urlEncoded)") else { throw ServiceError.invalidData }
        await MainActor.run { NSWorkspace.shared.open(url) }

        // Last.fm's desktop flow has no callback: poll until the user grants access in the browser.
        for _ in 0..<20 {
            try await Task.sleep(for: .seconds(3))
            if let sessionKey = try? await sessionKey(for: token) { return sessionKey }
        }
        throw ServiceError.response("Last.fm authorization timed out. Try again and approve access in the browser.")
    }

    private func sessionKey(for token: String) async throws -> String {
        let data = try await request(method: "auth.getSession", extra: ["token": token])
        guard let session = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["session"] as? [String: Any],
              let key = session["key"] as? String else { throw ServiceError.invalidData }
        return key
    }

    private func request(method: String, extra: [String: String] = [:]) async throws -> Data {
        var parameters = extra
        parameters["method"] = method
        parameters["api_key"] = apiKey
        let signatureText = parameters.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + sharedSecret
        parameters["api_sig"] = MD5.hex(signatureText)
        parameters["format"] = "json"
        var request = URLRequest(url: URL(string: "https://ws.audioscrobbler.com/2.0/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("SonosLastFM/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = parameters.map { "\($0.key.urlEncoded)=\($0.value.urlEncoded)" }.sorted().joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.response("Last.fm returned an HTTP error.") }
        if let body = try JSONSerialization.jsonObject(with: data) as? [String: Any], let message = body["message"] as? String { throw ServiceError.response("Last.fm: \(message)") }
        return data
    }
}

private extension Track { var normalized: Track { Track(title: title, artist: artist, album: album, duration: duration.map { $0 / 1000 }) } }
private extension String {
    var urlEncoded: String {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
    var urlPathEncoded: String { addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self }
}
// Last.fm's signed-write protocol explicitly specifies MD5; it is not used for storage or transport security.
private enum MD5 { static func hex(_ string: String) -> String { var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH)); let data = Data(string.utf8); _ = data.withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }; return digest.map { String(format: "%02x", $0) }.joined() } }
