//
//  LegacyTrackerModels.swift
//  AidokuLegacy
//
//  Minimal tracker integration models (AniList only).
//

import Foundation

// Identifies a supported tracker service.
enum LegacyTrackerId: String, Codable, CaseIterable {
    case anilist
    case myanimelist

    // Human-readable name shown in the UI.
    var displayName: String {
        switch self {
            case .anilist:
                return "AniList"
            case .myanimelist:
                return "MyAnimeList"
        }
    }
}

// Common operations shared by every tracker client, so the manager can route
// search/status/update/auth generically by LegacyTrackerId.
protocol LegacyTrackerService: AnyObject {
    var isAuthenticated: Bool { get }
    func getViewer(completion: @escaping (Result<String, Error>) -> Void)
    func search(title: String, completion: @escaping (Result<[LegacyTrackSearchResult], Error>) -> Void)
    func getStatus(remoteId: Int, completion: @escaping (Result<LegacyTrackRemoteState, Error>) -> Void)
    func update(
        remoteId: Int,
        status: LegacyTrackStatus?,
        progress: Int?,
        score: Float?,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func logout()
}

extension LegacyAniListTracker: LegacyTrackerService {}
extension LegacyMyAnimeListTracker: LegacyTrackerService {}

// Reading status of a tracked title, mirroring the common tracker states.
enum LegacyTrackStatus: String, Codable, CaseIterable {
    case reading
    case planning
    case completed
    case dropped
    case paused
    case rereading

    // Display title for status pickers.
    var displayName: String {
        switch self {
            case .reading:
                return LegacyString("tracker.status.reading")
            case .planning:
                return LegacyString("tracker.status.planning")
            case .completed:
                return LegacyString("tracker.status.completed")
            case .dropped:
                return LegacyString("tracker.status.dropped")
            case .paused:
                return LegacyString("tracker.status.paused")
            case .rereading:
                return LegacyString("tracker.status.rereading")
        }
    }
}

// High-level authentication state for a tracker.
enum LegacyTrackerAuthState: Equatable {
    case loggedOut
    case loggedIn
}

// A single tracked entry linking a local manga to a remote tracker record.
struct LegacyTrackEntry: Codable, Hashable {
    var sourceKey: String
    var mangaKey: String
    var trackerId: LegacyTrackerId
    var remoteId: Int
    var status: LegacyTrackStatus
    var lastReadChapter: Float
    var score: Float
    var totalChapters: Int

    init(
        sourceKey: String,
        mangaKey: String,
        trackerId: LegacyTrackerId,
        remoteId: Int,
        status: LegacyTrackStatus = .reading,
        lastReadChapter: Float = 0,
        score: Float = 0,
        totalChapters: Int = 0
    ) {
        self.sourceKey = sourceKey
        self.mangaKey = mangaKey
        self.trackerId = trackerId
        self.remoteId = remoteId
        self.status = status
        self.lastReadChapter = lastReadChapter
        self.score = score
        self.totalChapters = totalChapters
    }

    // Stable storage key: "trackerId::sourceKey::mangaKey".
    var key: String {
        return LegacyTrackEntry.makeKey(
            trackerId: trackerId,
            sourceKey: sourceKey,
            mangaKey: mangaKey
        )
    }

    // Builds the storage key without an existing entry.
    static func makeKey(trackerId: LegacyTrackerId, sourceKey: String, mangaKey: String) -> String {
        return "\(trackerId.rawValue)::\(sourceKey)::\(mangaKey)"
    }
}

// A search result candidate returned by a tracker for linking.
struct LegacyTrackSearchResult {
    var remoteId: Int
    var title: String
    var totalChapters: Int
    var coverURL: URL?

    init(remoteId: Int, title: String, totalChapters: Int = 0, coverURL: URL? = nil) {
        self.remoteId = remoteId
        self.title = title
        self.totalChapters = totalChapters
        self.coverURL = coverURL
    }
}

// The current remote state for a tracked title (used to seed the local entry).
struct LegacyTrackRemoteState {
    var status: LegacyTrackStatus
    var lastReadChapter: Float
    var score: Float
    var totalChapters: Int
}

// Errors surfaced by tracker network operations.
enum LegacyTrackerError: Error, LocalizedError {
    case notAuthenticated
    case invalidResponse
    case requestFailed(String)
    case noResults

    var errorDescription: String? {
        switch self {
            case .notAuthenticated:
                return "Not logged in to the tracker."
            case .invalidResponse:
                return "Received an invalid response from the tracker."
            case .requestFailed(let message):
                return message
            case .noResults:
                return "No matching titles were found."
        }
    }
}

// Notification posted whenever tracking state changes (entries or tokens).
extension Notification.Name {
    static let aidokuLegacyTrackingDidChange = Notification.Name("AidokuLegacyTrackingDidChange")
}
