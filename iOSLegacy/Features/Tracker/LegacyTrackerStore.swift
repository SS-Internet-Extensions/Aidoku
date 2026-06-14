//
//  LegacyTrackerStore.swift
//  AidokuLegacy
//
//  UserDefaults-backed persistence for tracker entries and access tokens.
//  Mirrors the LegacyLibraryStore / LegacyHistoryStore patterns.
//

import Foundation

final class LegacyTrackerStore {
    static let shared = LegacyTrackerStore()

    private let entriesKey = "AidokuLegacy.tracker.entries"
    private let tokensKey = "AidokuLegacy.tracker.tokens"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - Entries

    // All persisted track entries.
    var entries: [LegacyTrackEntry] {
        guard
            let data = UserDefaults.standard.data(forKey: entriesKey),
            let entries = try? decoder.decode([LegacyTrackEntry].self, from: data)
        else {
            return []
        }
        return entries
    }

    // Returns the entry for a given tracker/source/manga, if any.
    func entry(
        trackerId: LegacyTrackerId,
        sourceKey: String,
        mangaKey: String
    ) -> LegacyTrackEntry? {
        let key = LegacyTrackEntry.makeKey(trackerId: trackerId, sourceKey: sourceKey, mangaKey: mangaKey)
        return entries.first { $0.key == key }
    }

    // Convenience lookup using an entry as the query template.
    func entry(for entry: LegacyTrackEntry) -> LegacyTrackEntry? {
        return entries.first { $0.key == entry.key }
    }

    // Returns all entries for a given source/manga across all trackers.
    func entries(sourceKey: String, mangaKey: String) -> [LegacyTrackEntry] {
        return entries.filter { $0.sourceKey == sourceKey && $0.mangaKey == mangaKey }
    }

    // Inserts or updates an entry, keyed by its composite key.
    func save(_ entry: LegacyTrackEntry) {
        var current = entries.filter { $0.key != entry.key }
        current.insert(entry, at: 0)
        persist(current)
    }

    // Removes an entry matching the given entry's key.
    func remove(_ entry: LegacyTrackEntry) {
        persist(entries.filter { $0.key != entry.key })
    }

    // Removes any entry matching tracker/source/manga.
    func remove(trackerId: LegacyTrackerId, sourceKey: String, mangaKey: String) {
        let key = LegacyTrackEntry.makeKey(trackerId: trackerId, sourceKey: sourceKey, mangaKey: mangaKey)
        persist(entries.filter { $0.key != key })
    }

    // Replaces all entries (used by backup restore).
    func replace(_ entries: [LegacyTrackEntry]) {
        persist(entries)
    }

    // Clears all entries.
    func clearEntries() {
        persist([])
    }

    // MARK: - Tokens

    // Access tokens keyed by tracker id raw value.
    var tokens: [String: String] {
        guard
            let data = UserDefaults.standard.data(forKey: tokensKey),
            let tokens = try? decoder.decode([String: String].self, from: data)
        else {
            return [:]
        }
        return tokens
    }

    // Returns the stored access token for a tracker, if present.
    func token(for trackerId: LegacyTrackerId) -> String? {
        return tokens[trackerId.rawValue]
    }

    // Stores (or replaces) the access token for a tracker.
    func setToken(_ token: String, for trackerId: LegacyTrackerId) {
        var current = tokens
        current[trackerId.rawValue] = token
        persistTokens(current)
    }

    // Removes the stored token for a tracker.
    func clearToken(for trackerId: LegacyTrackerId) {
        var current = tokens
        current.removeValue(forKey: trackerId.rawValue)
        persistTokens(current)
    }

    // MARK: - Persistence

    private func persist(_ entries: [LegacyTrackEntry]) {
        if let data = try? encoder.encode(entries) {
            UserDefaults.standard.set(data, forKey: entriesKey)
            NotificationCenter.default.post(name: .aidokuLegacyTrackingDidChange, object: nil)
        }
    }

    private func persistTokens(_ tokens: [String: String]) {
        if let data = try? encoder.encode(tokens) {
            UserDefaults.standard.set(data, forKey: tokensKey)
            NotificationCenter.default.post(name: .aidokuLegacyTrackingDidChange, object: nil)
        }
    }
}
