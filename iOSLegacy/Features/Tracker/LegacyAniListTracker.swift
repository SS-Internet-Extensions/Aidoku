//
//  LegacyAniListTracker.swift
//  AidokuLegacy
//
//  AniList GraphQL client using URLSession completion handlers (iOS 12 safe).
//

import Foundation

// Default placeholder. A real AniList API client id is supplied at runtime by the
// user (Settings -> Trackers) and stored in UserDefaults; see `clientId` below.
let ANILIST_CLIENT_ID = "ANILIST_CLIENT_ID_PLACEHOLDER"

final class LegacyAniListTracker {
    static let shared = LegacyAniListTracker()

    private let trackerId: LegacyTrackerId = .anilist
    private let apiURL = URL(string: "https://graphql.anilist.co")!
    private let store = LegacyTrackerStore.shared
    private let session: URLSession
    private let clientIdDefaultsKey = "AidokuLegacy.tracker.anilist.clientId"

    init(session: URLSession = .shared) {
        self.session = session
    }

    // The effective AniList client id: a user-supplied value when present,
    // otherwise the compile-time placeholder.
    var clientId: String {
        if let stored = UserDefaults.standard.string(forKey: clientIdDefaultsKey), !stored.isEmpty {
            return stored
        }
        return ANILIST_CLIENT_ID
    }

    // Whether a usable (non-placeholder) client id has been configured.
    var isClientConfigured: Bool {
        let id = clientId
        return !id.isEmpty && id != "ANILIST_CLIENT_ID_PLACEHOLDER"
    }

    func setClientId(_ id: String) {
        UserDefaults.standard.set(id.trimmingCharacters(in: .whitespacesAndNewlines), forKey: clientIdDefaultsKey)
    }

    // MARK: - Auth

    // Whether an access token is currently stored.
    var isAuthenticated: Bool {
        return (store.token(for: trackerId)?.isEmpty == false)
    }

    // Implicit-grant authorization URL. The redirect carries the token in its fragment.
    var authorizationURL: URL {
        var components = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "token")
        ]
        // Force-unwrap is safe: the base string and query items are all valid.
        return components.url!
    }

    // Stores the access token captured from the redirect fragment.
    func setAccessToken(_ token: String) {
        store.setToken(token, for: trackerId)
    }

    // Clears the stored access token (logout).
    func logout() {
        store.clearToken(for: trackerId)
    }

    // Parses an `access_token` out of a redirect URL fragment, if present.
    // AniList implicit grant redirects to e.g. `app://auth#access_token=...&token_type=Bearer`.
    static func accessToken(fromRedirect url: URL) -> String? {
        guard let fragment = url.fragment, !fragment.isEmpty else {
            return nil
        }
        for pair in fragment.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2, parts[0] == "access_token" {
                return parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        return nil
    }

    // MARK: - Requests

    // Validates the current token by requesting the authenticated viewer.
    func getViewer(completion: @escaping (Result<String, Error>) -> Void) {
        let query = """
        query {
          Viewer {
            id
            name
          }
        }
        """
        perform(query: query, variables: [:]) { result in
            switch result {
                case .success(let json):
                    guard
                        let data = json["data"] as? [String: Any],
                        let viewer = data["Viewer"] as? [String: Any],
                        let name = viewer["name"] as? String
                    else {
                        completion(.failure(LegacyTrackerError.invalidResponse))
                        return
                    }
                    completion(.success(name))
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    // Searches AniList for manga matching a title.
    func search(
        title: String,
        completion: @escaping (Result<[LegacyTrackSearchResult], Error>) -> Void
    ) {
        let query = """
        query ($search: String) {
          Page(page: 1, perPage: 20) {
            media(search: $search, type: MANGA, format_in: [MANGA, ONE_SHOT, NOVEL]) {
              id
              chapters
              title { romaji english native }
              coverImage { large }
            }
          }
        }
        """
        perform(query: query, variables: ["search": title]) { result in
            switch result {
                case .success(let json):
                    guard
                        let data = json["data"] as? [String: Any],
                        let page = data["Page"] as? [String: Any],
                        let media = page["media"] as? [[String: Any]]
                    else {
                        completion(.failure(LegacyTrackerError.invalidResponse))
                        return
                    }
                    let results: [LegacyTrackSearchResult] = media.compactMap { item in
                        guard let id = item["id"] as? Int else { return nil }
                        let titles = item["title"] as? [String: Any]
                        let displayTitle = (titles?["english"] as? String)
                            ?? (titles?["romaji"] as? String)
                            ?? (titles?["native"] as? String)
                            ?? "Unknown"
                        let total = item["chapters"] as? Int ?? 0
                        var cover: URL?
                        if
                            let coverImage = item["coverImage"] as? [String: Any],
                            let large = coverImage["large"] as? String
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

    // Fetches the viewer's current list state for a media id.
    func getStatus(
        remoteId: Int,
        completion: @escaping (Result<LegacyTrackRemoteState, Error>) -> Void
    ) {
        let query = """
        query ($mediaId: Int) {
          Media(id: $mediaId) {
            chapters
            mediaListEntry {
              status
              progress
              score(format: POINT_100)
            }
          }
        }
        """
        perform(query: query, variables: ["mediaId": remoteId]) { result in
            switch result {
                case .success(let json):
                    guard
                        let data = json["data"] as? [String: Any],
                        let media = data["Media"] as? [String: Any]
                    else {
                        completion(.failure(LegacyTrackerError.invalidResponse))
                        return
                    }
                    let totalChapters = media["chapters"] as? Int ?? 0
                    let listEntry = media["mediaListEntry"] as? [String: Any]
                    let statusRaw = listEntry?["status"] as? String
                    let progress = listEntry?["progress"] as? Int ?? 0
                    let score = listEntry?["score"] as? Double ?? 0
                    let state = LegacyTrackRemoteState(
                        status: LegacyAniListTracker.status(fromRemote: statusRaw),
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

    // Pushes status/progress/score via the SaveMediaListEntry mutation.
    func update(
        remoteId: Int,
        status: LegacyTrackStatus?,
        progress: Int?,
        score: Float?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var variables: [String: Any] = ["mediaId": remoteId]
        if let status = status {
            variables["status"] = LegacyAniListTracker.remoteStatus(from: status)
        }
        if let progress = progress {
            variables["progress"] = progress
        }
        if let score = score {
            // AniList scoreRaw is an Int on the POINT_100 scale.
            variables["score"] = Int(score.rounded())
        }
        let query = """
        mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int, $score: Int) {
          SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, scoreRaw: $score) {
            id
          }
        }
        """
        perform(query: query, variables: variables) { result in
            switch result {
                case .success(let json):
                    if
                        let data = json["data"] as? [String: Any],
                        data["SaveMediaListEntry"] != nil
                    {
                        completion(.success(()))
                    } else {
                        completion(.failure(LegacyTrackerError.invalidResponse))
                    }
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    // MARK: - Networking

    // Executes a GraphQL request with the stored bearer token.
    private func perform(
        query: String,
        variables: [String: Any],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let token = store.token(for: trackerId), !token.isEmpty else {
            completion(.failure(LegacyTrackerError.notAuthenticated))
            return
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["query": query, "variables": variables]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            completion(.failure(error))
            return
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
            // Surface GraphQL-level errors when no usable data is present.
            if
                json["data"] == nil || (json["data"] as? NSNull) != nil,
                let errors = json["errors"] as? [[String: Any]],
                let message = errors.first?["message"] as? String
            {
                completion(.failure(LegacyTrackerError.requestFailed(message)))
                return
            }
            completion(.success(json))
        }
        task.resume()
    }

    // MARK: - Status mapping

    // Maps a local status to the AniList MediaListStatus enum value.
    private static func remoteStatus(from status: LegacyTrackStatus) -> String {
        switch status {
            case .reading:
                return "CURRENT"
            case .planning:
                return "PLANNING"
            case .completed:
                return "COMPLETED"
            case .dropped:
                return "DROPPED"
            case .paused:
                return "PAUSED"
            case .rereading:
                return "REPEATING"
        }
    }

    // Maps an AniList MediaListStatus value to a local status.
    private static func status(fromRemote raw: String?) -> LegacyTrackStatus {
        switch raw {
            case "CURRENT":
                return .reading
            case "PLANNING":
                return .planning
            case "COMPLETED":
                return .completed
            case "DROPPED":
                return .dropped
            case "PAUSED":
                return .paused
            case "REPEATING":
                return .rereading
            default:
                return .reading
        }
    }
}
