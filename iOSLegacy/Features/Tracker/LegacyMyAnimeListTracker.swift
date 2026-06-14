//
//  LegacyMyAnimeListTracker.swift
//  AidokuLegacy
//
//  MyAnimeList API v2 client using URLSession completion handlers (iOS 12 safe).
//

import Foundation

// Default placeholder. A real MyAnimeList API client id is supplied at runtime by
// the user (Settings -> Trackers) and stored in UserDefaults; see `clientId` below.
let MAL_CLIENT_ID = "MAL_CLIENT_ID_PLACEHOLDER"

final class LegacyMyAnimeListTracker {
    static let shared = LegacyMyAnimeListTracker()

    private let trackerId: LegacyTrackerId = .myanimelist
    private let apiURL = URL(string: "https://api.myanimelist.net/v2")!
    private let store = LegacyTrackerStore.shared
    private let session: URLSession
    private let clientIdDefaultsKey = "AidokuLegacy.tracker.mal.clientId"
    private let pkceDefaultsKey = "AidokuLegacy.tracker.mal.pkce"
    private let refreshDefaultsKey = "AidokuLegacy.tracker.mal.refresh"

    init(session: URLSession = .shared) {
        self.session = session
    }

    // The effective MyAnimeList client id: a user-supplied value when present,
    // otherwise the compile-time placeholder.
    var clientId: String {
        if let stored = UserDefaults.standard.string(forKey: clientIdDefaultsKey), !stored.isEmpty {
            return stored
        }
        return MAL_CLIENT_ID
    }

    // Whether a usable (non-placeholder) client id has been configured.
    var isClientConfigured: Bool {
        let id = clientId
        return !id.isEmpty && id != "MAL_CLIENT_ID_PLACEHOLDER"
    }

    func setClientId(_ id: String) {
        UserDefaults.standard.set(id.trimmingCharacters(in: .whitespacesAndNewlines), forKey: clientIdDefaultsKey)
    }

    // MARK: - Auth

    // Whether an access token is currently stored.
    var isAuthenticated: Bool {
        return (store.token(for: trackerId)?.isEmpty == false)
    }

    // PKCE authorization-code URL. MAL uses the "plain" challenge method, so the
    // code_challenge equals the freshly generated code_verifier (stored for the
    // subsequent token exchange).
    var authorizationURL: URL {
        let verifier = makeCodeVerifier()
        UserDefaults.standard.set(verifier, forKey: pkceDefaultsKey)
        let state = makeCodeVerifier()
        var components = URLComponents(string: "https://myanimelist.net/v1/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "code_challenge", value: verifier),
            URLQueryItem(name: "code_challenge_method", value: "plain"),
            URLQueryItem(name: "state", value: state)
        ]
        // Force-unwrap is safe: the base string and query items are all valid.
        return components.url!
    }

    // Exchanges an authorization code for an access token using the stored PKCE
    // verifier, then persists the access and refresh tokens.
    func exchangeCode(_ code: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let verifier = UserDefaults.standard.string(forKey: pkceDefaultsKey), !verifier.isEmpty else {
            completion(.failure(LegacyTrackerError.notAuthenticated))
            return
        }

        let url = URL(string: "https://myanimelist.net/v1/oauth2/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let form: [String: String] = [
            "client_id": clientId,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code"
        ]
        request.httpBody = LegacyMyAnimeListTracker.encodeForm(form).data(using: .utf8)

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(LegacyTrackerError.invalidResponse))
                return
            }
            guard
                let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
            else {
                completion(.failure(LegacyTrackerError.invalidResponse))
                return
            }
            // Surface OAuth-level errors when no token is present.
            guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
                let message = (json["error"] as? String)
                    ?? (json["message"] as? String)
                    ?? "Token exchange failed."
                completion(.failure(LegacyTrackerError.requestFailed(message)))
                return
            }
            self.store.setToken(accessToken, for: self.trackerId)
            if let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty {
                UserDefaults.standard.set(refreshToken, forKey: self.refreshDefaultsKey)
            }
            UserDefaults.standard.removeObject(forKey: self.pkceDefaultsKey)
            completion(.success(()))
        }
        task.resume()
    }

    // Clears the stored access token and refresh token (logout).
    func logout() {
        store.clearToken(for: trackerId)
        UserDefaults.standard.removeObject(forKey: refreshDefaultsKey)
        UserDefaults.standard.removeObject(forKey: pkceDefaultsKey)
    }

    // Parses a `code` out of a redirect URL query, if present.
    // MAL authorization-code redirects to e.g. `app://auth?code=...&state=...`.
    static func authorizationCode(fromRedirect url: URL) -> String? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems
        else {
            return nil
        }
        for item in items where item.name == "code" {
            if let value = item.value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    // MARK: - Requests

    // Validates the current token by requesting the authenticated user.
    func getViewer(completion: @escaping (Result<String, Error>) -> Void) {
        perform(method: "GET", path: "/users/@me", body: nil) { result in
            switch result {
                case .success(let json):
                    guard let name = json["name"] as? String else {
                        completion(.failure(LegacyTrackerError.invalidResponse))
                        return
                    }
                    completion(.success(name))
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    // Searches MyAnimeList for manga matching a title.
    func search(
        title: String,
        completion: @escaping (Result<[LegacyTrackSearchResult], Error>) -> Void
    ) {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "q", value: title),
            URLQueryItem(name: "fields", value: "num_chapters,main_picture"),
            URLQueryItem(name: "limit", value: "20")
        ]
        let path = "/manga?" + (components.percentEncodedQuery ?? "")
        perform(method: "GET", path: path, body: nil) { result in
            switch result {
                case .success(let json):
                    guard let data = json["data"] as? [[String: Any]] else {
                        completion(.failure(LegacyTrackerError.invalidResponse))
                        return
                    }
                    let results: [LegacyTrackSearchResult] = data.compactMap { entry in
                        guard
                            let node = entry["node"] as? [String: Any],
                            let id = node["id"] as? Int
                        else {
                            return nil
                        }
                        let displayTitle = (node["title"] as? String) ?? "Unknown"
                        let total = node["num_chapters"] as? Int ?? 0
                        var cover: URL?
                        if
                            let picture = node["main_picture"] as? [String: Any],
                            let large = picture["large"] as? String
                        {
                            cover = URL(string: large)
                        }
                        return LegacyTrackSearchResult(
                            remoteId: id,
                            title: displayTitle,
                            totalChapters: total,
                            coverURL: cover
                        )
                    }
                    completion(.success(results))
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    // Fetches the user's current list state for a manga id.
    func getStatus(
        remoteId: Int,
        completion: @escaping (Result<LegacyTrackRemoteState, Error>) -> Void
    ) {
        let fields = "num_chapters,my_list_status{status,score,num_chapters_read}"
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "fields", value: fields)]
        let path = "/manga/\(remoteId)?" + (components.percentEncodedQuery ?? "")
        perform(method: "GET", path: path, body: nil) { result in
            switch result {
                case .success(let json):
                    let totalChapters = json["num_chapters"] as? Int ?? 0
                    let listStatus = json["my_list_status"] as? [String: Any]
                    let statusRaw = listStatus?["status"] as? String
                    let progress = listStatus?["num_chapters_read"] as? Int ?? 0
                    let score = listStatus?["score"] as? Int ?? 0
                    let state = LegacyTrackRemoteState(
                        status: LegacyMyAnimeListTracker.status(fromRemote: statusRaw),
                        lastReadChapter: Float(progress),
                        score: Float(score),
                        totalChapters: totalChapters
                    )
                    completion(.success(state))
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    // Pushes status/progress/score via the my_list_status endpoint.
    func update(
        remoteId: Int,
        status: LegacyTrackStatus?,
        progress: Int?,
        score: Float?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var form: [String: String] = [:]
        if let status = status {
            form["status"] = LegacyMyAnimeListTracker.malStatus(from: status)
        }
        if let progress = progress {
            form["num_chapters_read"] = String(progress)
        }
        if let score = score {
            // MAL scores use a 0-10 integer scale.
            var clamped = Int(score.rounded())
            if clamped < 0 { clamped = 0 }
            if clamped > 10 { clamped = 10 }
            form["score"] = String(clamped)
        }
        let body = LegacyMyAnimeListTracker.encodeForm(form).data(using: .utf8)
        perform(method: "PATCH", path: "/manga/\(remoteId)/my_list_status", body: body) { result in
            switch result {
                case .success:
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    // MARK: - Networking

    // Executes a REST request with the stored bearer token. A form-urlencoded
    // body (when present) is sent with the appropriate content type.
    private func perform(
        method: String,
        path: String,
        body: Data?,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let token = store.token(for: trackerId), !token.isEmpty else {
            completion(.failure(LegacyTrackerError.notAuthenticated))
            return
        }

        guard let url = URL(string: apiURL.absoluteString + path) else {
            completion(.failure(LegacyTrackerError.invalidResponse))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body = body {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                completion(.failure(LegacyTrackerError.notAuthenticated))
                return
            }
            guard let data = data else {
                completion(.failure(LegacyTrackerError.invalidResponse))
                return
            }
            guard
                let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
            else {
                completion(.failure(LegacyTrackerError.invalidResponse))
                return
            }
            // Surface API-level errors when present.
            if
                let errorName = json["error"] as? String,
                json["data"] == nil
            {
                let message = (json["message"] as? String) ?? errorName
                completion(.failure(LegacyTrackerError.requestFailed(message)))
                return
            }
            completion(.success(json))
        }
        task.resume()
    }

    // MARK: - PKCE

    // Generates a random PKCE code_verifier: a 64-character string drawn from the
    // unreserved character set (length is within the 43-128 range MAL accepts).
    private func makeCodeVerifier() -> String {
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        let characters = Array(allowed)
        var verifier = ""
        for _ in 0..<64 {
            let index = Int(arc4random_uniform(UInt32(characters.count)))
            verifier.append(characters[index])
        }
        return verifier
    }

    // MARK: - Form encoding

    // Encodes a dictionary as an application/x-www-form-urlencoded body.
    private static func encodeForm(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
    }

    // MARK: - Status mapping

    // Maps a local status to the MyAnimeList status string.
    private static func malStatus(from status: LegacyTrackStatus) -> String {
        switch status {
            case .reading:
                return "reading"
            case .planning:
                return "plan_to_read"
            case .completed:
                return "completed"
            case .dropped:
                return "dropped"
            case .paused:
                return "on_hold"
            case .rereading:
                // MAL has no distinct re-reading list status; reading is the
                // closest equivalent and the re_reading flag is read-only.
                return "reading"
        }
    }

    // Maps a MyAnimeList status string to a local status.
    private static func status(fromRemote raw: String?) -> LegacyTrackStatus {
        switch raw {
            case "reading":
                return .reading
            case "plan_to_read":
                return .planning
            case "completed":
                return .completed
            case "dropped":
                return .dropped
            case "on_hold":
                return .paused
            case "re_reading":
                return .rereading
            default:
                return .reading
        }
    }
}
