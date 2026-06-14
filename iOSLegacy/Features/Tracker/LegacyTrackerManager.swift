//
//  LegacyTrackerManager.swift
//  AidokuLegacy
//
//  Façade tying the tracker store and the individual tracker clients (AniList,
//  MyAnimeList) together. Callback-based; routes every operation by LegacyTrackerId.
//

import Foundation

final class LegacyTrackerManager {
    static let shared = LegacyTrackerManager()

    private let store: LegacyTrackerStore
    let anilist: LegacyAniListTracker
    let myanimelist: LegacyMyAnimeListTracker

    init(
        store: LegacyTrackerStore = .shared,
        anilist: LegacyAniListTracker = .shared,
        myanimelist: LegacyMyAnimeListTracker = .shared
    ) {
        self.store = store
        self.anilist = anilist
        self.myanimelist = myanimelist
    }

    // Resolves the client backing a tracker id.
    private func service(for id: LegacyTrackerId) -> LegacyTrackerService {
        switch id {
            case .anilist:
                return anilist
            case .myanimelist:
                return myanimelist
        }
    }

    // MARK: - Auth

    // Tracker ids that currently have a stored access token.
    var loggedInTrackers: [LegacyTrackerId] {
        return LegacyTrackerId.allCases.filter { service(for: $0).isAuthenticated }
    }

    // Whether any tracker is logged in.
    var isLoggedIn: Bool {
        return !loggedInTrackers.isEmpty
    }

    // Whether a specific tracker is logged in.
    func isLoggedIn(_ id: LegacyTrackerId) -> Bool {
        return service(for: id).isAuthenticated
    }

    // Validates the stored token for a tracker; returns the viewer name on success.
    func validateLogin(_ id: LegacyTrackerId, completion: @escaping (Result<String, Error>) -> Void) {
        service(for: id).getViewer(completion: completion)
    }

    // Logs out of a tracker and removes all of its tracked entries.
    func logout(_ id: LegacyTrackerId) {
        service(for: id).logout()
        for entry in store.entries where entry.trackerId == id {
            store.remove(entry)
        }
    }

    // MARK: - Linking

    // Searches a tracker for candidates matching a manga title.
    func search(
        trackerId: LegacyTrackerId,
        title: String,
        completion: @escaping (Result<[LegacyTrackSearchResult], Error>) -> Void
    ) {
        service(for: trackerId).search(title: title, completion: completion)
    }

    // Returns the entry for a manga on a specific tracker, if any.
    func entry(trackerId: LegacyTrackerId, sourceKey: String, mangaKey: String) -> LegacyTrackEntry? {
        return store.entry(trackerId: trackerId, sourceKey: sourceKey, mangaKey: mangaKey)
    }

    // Returns all tracker entries for a manga across every tracker.
    func entries(sourceKey: String, mangaKey: String) -> [LegacyTrackEntry] {
        return store.entries(sourceKey: sourceKey, mangaKey: mangaKey)
    }

    // Links a manga to a remote tracker record, seeding local state from the remote.
    func link(
        trackerId: LegacyTrackerId,
        sourceKey: String,
        mangaKey: String,
        remoteId: Int,
        completion: @escaping (Result<LegacyTrackEntry, Error>) -> Void
    ) {
        service(for: trackerId).getStatus(remoteId: remoteId) { [weak self] result in
            guard let self = self else { return }
            switch result {
                case .success(let state):
                    let entry = LegacyTrackEntry(
                        sourceKey: sourceKey,
                        mangaKey: mangaKey,
                        trackerId: trackerId,
                        remoteId: remoteId,
                        status: state.status,
                        lastReadChapter: state.lastReadChapter,
                        score: state.score,
                        totalChapters: state.totalChapters
                    )
                    self.store.save(entry)
                    completion(.success(entry))
                case .failure(let error):
                    // Still record a minimal link so the user keeps the association.
                    let entry = LegacyTrackEntry(
                        sourceKey: sourceKey,
                        mangaKey: mangaKey,
                        trackerId: trackerId,
                        remoteId: remoteId
                    )
                    self.store.save(entry)
                    completion(.failure(error))
            }
        }
    }

    // Removes a manga's link on a specific tracker locally (does not touch the remote list).
    func unlink(trackerId: LegacyTrackerId, sourceKey: String, mangaKey: String) {
        store.remove(trackerId: trackerId, sourceKey: sourceKey, mangaKey: mangaKey)
    }

    // MARK: - Sync

    // Pushes the latest read chapter to every linked tracker for a manga and updates
    // the local entries. No-ops (success) when nothing is linked or already ahead.
    func syncProgress(
        sourceKey: String,
        mangaKey: String,
        chapterNumber: Float,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        let entries = store.entries(sourceKey: sourceKey, mangaKey: mangaKey)
            .filter { isLoggedIn($0.trackerId) && chapterNumber > $0.lastReadChapter }
        guard !entries.isEmpty else {
            completion?(.success(()))
            return
        }

        var remaining = entries.count
        var firstError: Error?
        for entry in entries {
            syncEntry(entry, chapterNumber: chapterNumber) { result in
                if case .failure(let error) = result, firstError == nil {
                    firstError = error
                }
                remaining -= 1
                if remaining == 0 {
                    if let firstError = firstError {
                        completion?(.failure(firstError))
                    } else {
                        completion?(.success(()))
                    }
                }
            }
        }
    }

    // Pushes progress for a single entry, advancing status when appropriate.
    private func syncEntry(
        _ entry: LegacyTrackEntry,
        chapterNumber: Float,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var entry = entry
        let progress = Int(chapterNumber.rounded(.down))
        // Auto-complete when reaching the known total; advance planning -> reading.
        var newStatus: LegacyTrackStatus?
        if entry.totalChapters > 0, progress >= entry.totalChapters, entry.status != .completed {
            newStatus = .completed
        } else if entry.status == .planning {
            newStatus = .reading
        }

        service(for: entry.trackerId).update(
            remoteId: entry.remoteId,
            status: newStatus,
            progress: progress,
            score: nil
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
                case .success:
                    entry.lastReadChapter = chapterNumber
                    if let newStatus = newStatus {
                        entry.status = newStatus
                    }
                    self.store.save(entry)
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    // Pushes an explicit status/score change to the entry's tracker and updates locally.
    func updateEntry(
        _ entry: LegacyTrackEntry,
        status: LegacyTrackStatus?,
        score: Float?,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        var updated = entry
        service(for: entry.trackerId).update(
            remoteId: entry.remoteId,
            status: status,
            progress: Int(entry.lastReadChapter.rounded(.down)),
            score: score
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
                case .success:
                    if let status = status {
                        updated.status = status
                    }
                    if let score = score {
                        updated.score = score
                    }
                    self.store.save(updated)
                    completion?(.success(()))
                case .failure(let error):
                    completion?(.failure(error))
            }
        }
    }
}
