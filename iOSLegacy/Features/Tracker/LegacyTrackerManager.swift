//
//  LegacyTrackerManager.swift
//  AidokuLegacy
//
//  Façade tying the tracker store and the AniList client together. Callback-based.
//

import Foundation

final class LegacyTrackerManager {
    static let shared = LegacyTrackerManager()

    private let store: LegacyTrackerStore
    private let anilist: LegacyAniListTracker

    init(
        store: LegacyTrackerStore = .shared,
        anilist: LegacyAniListTracker = .shared
    ) {
        self.store = store
        self.anilist = anilist
    }

    // MARK: - Auth

    // Whether the AniList tracker has a stored access token.
    var isLoggedIn: Bool {
        return anilist.isAuthenticated
    }

    // Validates the stored token against AniList; returns the viewer name on success.
    func validateLogin(completion: @escaping (Result<String, Error>) -> Void) {
        anilist.getViewer(completion: completion)
    }

    // Logs out of AniList and removes all of its tracked entries.
    func logout() {
        anilist.logout()
        for entry in store.entries where entry.trackerId == .anilist {
            store.remove(entry)
        }
    }

    // MARK: - Linking

    // Searches AniList for candidates matching a manga title.
    func search(
        title: String,
        completion: @escaping (Result<[LegacyTrackSearchResult], Error>) -> Void
    ) {
        anilist.search(title: title, completion: completion)
    }

    // Returns the existing AniList entry for a manga, if any.
    func entry(sourceKey: String, mangaKey: String) -> LegacyTrackEntry? {
        return store.entry(trackerId: .anilist, sourceKey: sourceKey, mangaKey: mangaKey)
    }

    // Links a manga to an AniList media id, seeding local state from the remote record.
    func link(
        sourceKey: String,
        mangaKey: String,
        remoteId: Int,
        completion: @escaping (Result<LegacyTrackEntry, Error>) -> Void
    ) {
        anilist.getStatus(remoteId: remoteId) { [weak self] result in
            guard let self = self else { return }
            switch result {
                case .success(let state):
                    let entry = LegacyTrackEntry(
                        sourceKey: sourceKey,
                        mangaKey: mangaKey,
                        trackerId: .anilist,
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
                        trackerId: .anilist,
                        remoteId: remoteId
                    )
                    self.store.save(entry)
                    completion(.failure(error))
            }
        }
    }

    // Removes the AniList link for a manga locally (does not touch the remote list).
    func unlink(sourceKey: String, mangaKey: String) {
        store.remove(trackerId: .anilist, sourceKey: sourceKey, mangaKey: mangaKey)
    }

    // MARK: - Sync

    // Pushes the latest read chapter to AniList and updates the local entry.
    // No-ops (success) when no link exists or the new chapter is not ahead.
    func syncProgress(
        sourceKey: String,
        mangaKey: String,
        chapterNumber: Float,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        guard isLoggedIn else {
            completion?(.success(()))
            return
        }
        guard var entry = store.entry(trackerId: .anilist, sourceKey: sourceKey, mangaKey: mangaKey) else {
            completion?(.success(()))
            return
        }
        // Only advance progress; never move it backwards.
        guard chapterNumber > entry.lastReadChapter else {
            completion?(.success(()))
            return
        }

        let progress = Int(chapterNumber.rounded(.down))
        // Auto-complete when reaching the known total.
        var newStatus: LegacyTrackStatus? = nil
        if entry.totalChapters > 0, progress >= entry.totalChapters, entry.status != .completed {
            newStatus = .completed
        } else if entry.status == .planning {
            newStatus = .reading
        }

        anilist.update(
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
                    completion?(.success(()))
                case .failure(let error):
                    completion?(.failure(error))
            }
        }
    }

    // Pushes an explicit status/score change to AniList and updates the local entry.
    func updateEntry(
        _ entry: LegacyTrackEntry,
        status: LegacyTrackStatus?,
        score: Float?,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        var updated = entry
        anilist.update(
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
