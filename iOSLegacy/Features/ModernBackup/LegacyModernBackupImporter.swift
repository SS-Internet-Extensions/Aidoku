//
//  LegacyModernBackupImporter.swift
//  AidokuLegacy
//
//  Imports a modern Aidoku backup (JSON) into the legacy stores.
//
//  The modern format normalises its data: library/history/update rows reference
//  manga and chapters by (sourceId, mangaId[, chapterId]) and the full payloads
//  live in separate top-level `manga` / `chapters` arrays. The legacy stores
//  instead embed the full `AidokuRunnerLegacyManga` / `AidokuRunnerLegacyChapter`
//  in each row, so the importer joins the normalised modern data back together
//  before writing it through the existing legacy store `replace(...)` APIs.
//
//  iOS 12 constraints: UIKit only, no async/await — the public entry point is a
//  synchronous throwing function plus a completion-based convenience wrapper.
//

import Foundation

enum LegacyModernBackupImportError: Error {
    case unreadableFile
    case invalidFormat
}

struct LegacyModernBackupImportResult {
    var libraryAdded: Int
    var historyAdded: Int
    var updatesAdded: Int
    var repositoriesAdded: Int
}

final class LegacyModernBackupImporter {
    static let shared = LegacyModernBackupImporter()

    private let decoder: JSONDecoder

    init() {
        let decoder = JSONDecoder()
        // Modern JSON backups encode dates as seconds since 1970.
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    // Decodes a modern backup at `url` and merges it into the legacy stores.
    // `merge == true` (default) keeps existing legacy entries and adds/overwrites
    // matching keys; `merge == false` replaces the legacy data wholesale.
    @discardableResult
    func importBackup(at url: URL, merge: Bool = true) throws -> LegacyModernBackupImportResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LegacyModernBackupImportError.unreadableFile
        }

        let backup: LegacyModernBackup
        do {
            backup = try decoder.decode(LegacyModernBackup.self, from: data)
        } catch {
            throw LegacyModernBackupImportError.invalidFormat
        }

        return apply(backup: backup, merge: merge)
    }

    // Completion-based convenience for callers that prefer not to handle throws
    // inline. Decoding/merge runs on a background queue; the completion is
    // delivered on the main queue.
    func importBackup(
        at url: URL,
        merge: Bool = true,
        completion: @escaping (Result<LegacyModernBackupImportResult, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<LegacyModernBackupImportResult, Error>
            do {
                let value = try self.importBackup(at: url, merge: merge)
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    // MARK: - Merge

    private func apply(backup: LegacyModernBackup, merge: Bool) -> LegacyModernBackupImportResult {
        // Index manga and chapters for fast lookup by their composite keys.
        let mangaIndex = buildMangaIndex(backup.manga ?? [])
        let chaptersByManga = buildChapterIndex(backup.chapters ?? [])

        let library = buildLibrary(
            backup: backup,
            mangaIndex: mangaIndex,
            chaptersByManga: chaptersByManga
        )
        let history = buildHistory(
            backup: backup,
            mangaIndex: mangaIndex,
            chaptersByManga: chaptersByManga
        )
        let updates = buildUpdates(
            backup: backup,
            mangaIndex: mangaIndex,
            chaptersByManga: chaptersByManga
        )
        let sessionHistory = buildReadingSessionHistory(
            backup: backup,
            mangaIndex: mangaIndex,
            chaptersByManga: chaptersByManga
        )
        let tracks = buildTrackItems(backup: backup)

        let mergedLibrary = mergedLibraryEntries(imported: library, merge: merge)
        let mergedHistory = mergedHistoryEntries(imported: history + sessionHistory, merge: merge)
        let mergedUpdates = mergedUpdateEntries(imported: updates, merge: merge)
        let mergedTracks = mergedTrackEntries(imported: tracks, merge: merge)

        LegacyLibraryStore.shared.replace(mergedLibrary)
        LegacyHistoryStore.shared.replace(mergedHistory)
        LegacyUpdateStore.shared.replace(mergedUpdates)
        LegacyTrackerStore.shared.replace(mergedTracks)

        let repositoriesAdded = applyRepositories(backup.sourceLists ?? [], merge: merge)
        applySettings(backup.settings ?? [:], sourceIds: sourceIds(from: backup))

        return LegacyModernBackupImportResult(
            libraryAdded: library.count,
            historyAdded: history.count + sessionHistory.count,
            updatesAdded: updates.count,
            repositoriesAdded: repositoriesAdded
        )
    }

    // MARK: - Indexing

    private func mangaKey(sourceId: String, mangaId: String) -> String {
        return "\(sourceId)::\(mangaId)"
    }

    private func chapterKey(sourceId: String, mangaId: String, chapterId: String) -> String {
        return "\(sourceId)::\(mangaId)::\(chapterId)"
    }

    private func buildMangaIndex(_ manga: [LegacyModernBackupManga]) -> [String: LegacyModernBackupManga] {
        var index: [String: LegacyModernBackupManga] = [:]
        for entry in manga {
            index[mangaKey(sourceId: entry.sourceId, mangaId: entry.id)] = entry
        }
        return index
    }

    // Chapters grouped by their owning manga, so we can attach the full chapter
    // list onto each legacy manga, and resolve individual chapters by id.
    private func buildChapterIndex(
        _ chapters: [LegacyModernBackupChapter]
    ) -> [String: [LegacyModernBackupChapter]] {
        var index: [String: [LegacyModernBackupChapter]] = [:]
        for chapter in chapters {
            let key = mangaKey(sourceId: chapter.sourceId, mangaId: chapter.mangaId)
            index[key, default: []].append(chapter)
        }
        // Preserve modern source ordering where present (smaller order first).
        for (key, value) in index {
            index[key] = value.sorted { ($0.sourceOrder ?? 0) < ($1.sourceOrder ?? 0) }
        }
        return index
    }

    // MARK: - Mapping helpers

    private func legacyManga(
        from modern: LegacyModernBackupManga,
        chapters: [LegacyModernBackupChapter]?
    ) -> AidokuRunnerLegacyManga {
        return AidokuRunnerLegacyManga(
            sourceKey: modern.sourceId,
            key: modern.id,
            title: modern.title,
            cover: modern.cover,
            artists: modern.artist.map { [$0] },
            authors: modern.author.map { [$0] },
            description: modern.desc,
            url: modern.url.flatMap { URL(string: $0) },
            tags: modern.tags,
            status: publishingStatus(from: modern.status),
            contentRating: contentRating(from: modern.nsfw),
            viewer: viewer(from: modern.viewer),
            updateStrategy: .always,
            nextUpdateTime: modern.nextUpdateTime.map { Int($0.timeIntervalSince1970) },
            chapters: chapters?.map { legacyChapter(from: $0) }
        )
    }

    // Builds a minimal legacy manga when the backup references a manga id that has
    // no matching entry in the top-level `manga` array.
    private func placeholderManga(sourceId: String, mangaId: String) -> AidokuRunnerLegacyManga {
        return AidokuRunnerLegacyManga(
            sourceKey: sourceId,
            key: mangaId,
            title: mangaId,
            cover: nil,
            artists: nil,
            authors: nil,
            description: nil,
            url: nil,
            tags: nil,
            status: .unknown,
            contentRating: .unknown,
            viewer: .unknown,
            updateStrategy: .always,
            nextUpdateTime: nil,
            chapters: nil
        )
    }

    private func legacyChapter(from modern: LegacyModernBackupChapter) -> AidokuRunnerLegacyChapter {
        return AidokuRunnerLegacyChapter(
            key: modern.id,
            title: modern.title,
            chapterNumber: modern.chapter,
            volumeNumber: modern.volume,
            dateUploaded: modern.dateUploaded,
            scanlators: modern.scanlator.map { [$0] },
            url: modern.url.flatMap { URL(string: $0) },
            language: modern.lang,
            thumbnail: modern.thumbnail,
            locked: modern.locked ?? false
        )
    }

    // MARK: - Library

    private func buildLibrary(
        backup: LegacyModernBackup,
        mangaIndex: [String: LegacyModernBackupManga],
        chaptersByManga: [String: [LegacyModernBackupChapter]]
    ) -> [LegacyLibraryEntry] {
        guard let library = backup.library else { return [] }
        var entries: [LegacyLibraryEntry] = []
        for row in library {
            let key = mangaKey(sourceId: row.sourceId, mangaId: row.mangaId)
            let chapters = chaptersByManga[key]
            let manga: AidokuRunnerLegacyManga
            if let modern = mangaIndex[key] {
                manga = legacyManga(from: modern, chapters: chapters)
            } else {
                manga = placeholderManga(sourceId: row.sourceId, mangaId: row.mangaId)
            }
            let categories = row.categories ?? []
            let entry = LegacyLibraryEntry(
                sourceKey: row.sourceId,
                sourceName: row.sourceId,
                manga: manga,
                dateAdded: row.dateAdded ?? Date(),
                category: categories.first,
                categories: categories
            )
            entries.append(entry)
        }
        return entries
    }

    // MARK: - History

    private func buildHistory(
        backup: LegacyModernBackup,
        mangaIndex: [String: LegacyModernBackupManga],
        chaptersByManga: [String: [LegacyModernBackupChapter]]
    ) -> [LegacyHistoryEntry] {
        guard let history = backup.history else { return [] }
        var entries: [LegacyHistoryEntry] = []
        for row in history {
            let key = mangaKey(sourceId: row.sourceId, mangaId: row.mangaId)
            let chapters = chaptersByManga[key]
            let manga: AidokuRunnerLegacyManga
            if let modern = mangaIndex[key] {
                manga = legacyManga(from: modern, chapters: chapters)
            } else {
                manga = placeholderManga(sourceId: row.sourceId, mangaId: row.mangaId)
            }
            let chapter = resolveChapter(
                sourceId: row.sourceId,
                mangaId: row.mangaId,
                chapterId: row.chapterId,
                chapters: chapters
            )
            let entry = LegacyHistoryEntry(
                sourceKey: row.sourceId,
                sourceName: row.sourceId,
                manga: manga,
                chapter: chapter,
                pageIndex: max(0, row.progress ?? 0),
                pageCount: max(0, row.total ?? 0),
                dateRead: row.dateRead ?? Date()
            )
            entries.append(entry)
        }
        return entries
    }

    // MARK: - Updates

    private func buildUpdates(
        backup: LegacyModernBackup,
        mangaIndex: [String: LegacyModernBackupManga],
        chaptersByManga: [String: [LegacyModernBackupChapter]]
    ) -> [LegacyUpdateEntry] {
        guard let updates = backup.updates else { return [] }
        var entries: [LegacyUpdateEntry] = []
        for row in updates {
            let key = mangaKey(sourceId: row.sourceId, mangaId: row.mangaId)
            let chapters = chaptersByManga[key]
            let manga: AidokuRunnerLegacyManga
            if let modern = mangaIndex[key] {
                manga = legacyManga(from: modern, chapters: chapters)
            } else {
                manga = placeholderManga(sourceId: row.sourceId, mangaId: row.mangaId)
            }
            let chapter = resolveChapter(
                sourceId: row.sourceId,
                mangaId: row.mangaId,
                chapterId: row.chapterId,
                chapters: chapters
            )
            let entry = LegacyUpdateEntry(
                sourceKey: row.sourceId,
                sourceName: row.sourceId,
                manga: manga,
                chapter: chapter,
                dateFound: row.date ?? Date()
            )
            entries.append(entry)
        }
        return entries
    }

    // MARK: - Tracking

    private func buildTrackItems(backup: LegacyModernBackup) -> [LegacyTrackEntry] {
        guard let trackItems = backup.trackItems else { return [] }
        return trackItems.compactMap { item in
            guard
                let trackerId = LegacyTrackerId(rawValue: item.trackerId),
                let remoteId = Int(item.id),
                !item.sourceId.isEmpty,
                !item.mangaId.isEmpty
            else {
                return nil
            }
            return LegacyTrackEntry(
                sourceKey: item.sourceId,
                mangaKey: item.mangaId,
                trackerId: trackerId,
                remoteId: remoteId,
                status: .reading,
                lastReadChapter: Float(item.chapterOffset ?? 0),
                score: 0,
                totalChapters: 0
            )
        }
    }

    // MARK: - Reading Sessions

    private func buildReadingSessionHistory(
        backup: LegacyModernBackup,
        mangaIndex: [String: LegacyModernBackupManga],
        chaptersByManga: [String: [LegacyModernBackupChapter]]
    ) -> [LegacyHistoryEntry] {
        guard let sessions = backup.readingSessions else { return [] }
        var entries: [LegacyHistoryEntry] = []
        for session in sessions {
            let key = mangaKey(sourceId: session.sourceId, mangaId: session.mangaId)
            let chapters = chaptersByManga[key]
            let manga: AidokuRunnerLegacyManga
            if let modern = mangaIndex[key] {
                manga = legacyManga(from: modern, chapters: chapters)
            } else {
                manga = placeholderManga(sourceId: session.sourceId, mangaId: session.mangaId)
            }
            let chapter = resolveChapter(
                sourceId: session.sourceId,
                mangaId: session.mangaId,
                chapterId: session.chapterId,
                chapters: chapters
            )
            entries.append(
                LegacyHistoryEntry(
                    sourceKey: session.sourceId,
                    sourceName: session.sourceId,
                    manga: manga,
                    chapter: chapter,
                    pageIndex: max(0, session.pagesRead - 1),
                    pageCount: max(0, session.pagesRead),
                    dateRead: session.endDate
                )
            )
        }
        return entries
    }

    // Finds the full chapter payload for a referenced chapter id, falling back to
    // a minimal chapter carrying just the id when the backup omits the payload.
    private func resolveChapter(
        sourceId: String,
        mangaId: String,
        chapterId: String,
        chapters: [LegacyModernBackupChapter]?
    ) -> AidokuRunnerLegacyChapter {
        if let match = chapters?.first(where: { $0.id == chapterId }) {
            return legacyChapter(from: match)
        }
        return AidokuRunnerLegacyChapter(key: chapterId)
    }

    // MARK: - Merge strategies

    private func mergedLibraryEntries(
        imported: [LegacyLibraryEntry],
        merge: Bool
    ) -> [LegacyLibraryEntry] {
        guard merge else { return imported }
        var result = LegacyLibraryStore.shared.rawEntries
        var indexByKey: [String: Int] = [:]
        for (index, entry) in result.enumerated() {
            indexByKey[entry.key] = index
        }
        for entry in imported {
            if let index = indexByKey[entry.key] {
                result[index] = entry
            } else {
                indexByKey[entry.key] = result.count
                result.append(entry)
            }
        }
        return result
    }

    private func mergedHistoryEntries(
        imported: [LegacyHistoryEntry],
        merge: Bool
    ) -> [LegacyHistoryEntry] {
        guard merge else { return imported }
        var result = LegacyHistoryStore.shared.entries
        var indexByKey: [String: Int] = [:]
        for (index, entry) in result.enumerated() {
            indexByKey[entry.key] = index
        }
        for entry in imported {
            if let index = indexByKey[entry.key] {
                // Keep whichever record was read more recently.
                if entry.dateRead >= result[index].dateRead {
                    result[index] = entry
                }
            } else {
                indexByKey[entry.key] = result.count
                result.append(entry)
            }
        }
        return result
    }

    private func mergedUpdateEntries(
        imported: [LegacyUpdateEntry],
        merge: Bool
    ) -> [LegacyUpdateEntry] {
        guard merge else { return imported }
        var result = LegacyUpdateStore.shared.entries
        var indexByKey: [String: Int] = [:]
        for (index, entry) in result.enumerated() {
            indexByKey[entry.key] = index
        }
        for entry in imported {
            if let index = indexByKey[entry.key] {
                result[index] = entry
            } else {
                indexByKey[entry.key] = result.count
                result.append(entry)
            }
        }
        return result
    }

    private func mergedTrackEntries(
        imported: [LegacyTrackEntry],
        merge: Bool
    ) -> [LegacyTrackEntry] {
        guard merge else { return imported }
        var result = LegacyTrackerStore.shared.entries
        var indexByKey: [String: Int] = [:]
        for (index, entry) in result.enumerated() {
            indexByKey[entry.key] = index
        }
        for entry in imported {
            if let index = indexByKey[entry.key] {
                result[index] = entry
            } else {
                indexByKey[entry.key] = result.count
                result.append(entry)
            }
        }
        return result
    }

    // Adds any modern source-list (repository) URLs that are not already present.
    // Returns the number of newly added repositories.
    private func applyRepositories(_ urlStrings: [String], merge: Bool) -> Int {
        let store = LegacySourceRepositoryStore.shared
        let parsed = urlStrings.compactMap { URL(string: $0) }
        guard !parsed.isEmpty else { return 0 }

        if !merge {
            store.replace(with: parsed)
            return parsed.count
        }

        let existing = Set(store.repositoryURLs.map { $0.absoluteString })
        var added = 0
        for url in parsed where !existing.contains(url.absoluteString) {
            store.add(url)
            added += 1
        }
        return added
    }

    // MARK: - Settings

    private func sourceIds(from backup: LegacyModernBackup) -> [String] {
        var ids = Set<String>()
        for source in backup.sources ?? [] {
            ids.insert(source.id)
        }
        for manga in backup.manga ?? [] {
            ids.insert(manga.sourceId)
        }
        return Array(ids)
    }

    private func applySettings(_ settings: [String: LegacyModernBackupSettingValue], sourceIds: [String]) {
        var didApply = false
        for (key, value) in settings where shouldApplySetting(key: key, sourceIds: sourceIds) {
            if let rawValue = value.rawValue {
                UserDefaults.standard.set(rawValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            didApply = true
        }
        if didApply {
            NotificationCenter.default.post(name: .legacyAppearanceDidChange, object: nil)
            NotificationCenter.default.post(name: .legacyInstalledSourcesDidChange, object: nil)
        }
    }

    private func shouldApplySetting(key: String, sourceIds: [String]) -> Bool {
        if key == "AidokuLegacy.library.entries"
            || key == "AidokuLegacy.history.entries"
            || key == "AidokuLegacy.updates.entries"
            || key == "AidokuLegacy.tracker.entries"
            || key == "AidokuLegacy.tracker.tokens" {
            return false
        }
        if key.hasPrefix("AidokuLegacy.reader.")
            || key.hasPrefix("AidokuLegacy.appearance.")
            || key.hasPrefix("AidokuLegacy.library.")
            || key.hasPrefix("AidokuLegacy.sources.")
            || key.hasPrefix("AidokuLegacy.backup.")
            || key.hasPrefix("AidokuLegacy.downloads.")
            || key.hasPrefix("AidokuLegacy.privacy.")
            || key.hasPrefix("AidokuLegacy.network.")
            || key.hasPrefix("AidokuLegacy.notifications.") {
            return true
        }
        if sourceIds.contains(where: { key.hasPrefix("\($0).") }) {
            return true
        }
        return key.hasSuffix(".languages") || key.hasSuffix(".language") || key.hasSuffix(".url")
    }

    private func publishingStatus(from value: Int?) -> PublishingStatus {
        guard let value = value, let raw = UInt8(exactly: value), let status = PublishingStatus(rawValue: raw) else {
            return .unknown
        }
        return status
    }

    private func contentRating(from value: Int?) -> ContentRating {
        guard let value = value, let raw = UInt8(exactly: value), let rating = ContentRating(rawValue: raw) else {
            return .unknown
        }
        return rating
    }

    private func viewer(from value: Int?) -> Viewer {
        guard let value = value, let raw = UInt8(exactly: value), let viewer = Viewer(rawValue: raw) else {
            return .unknown
        }
        return viewer
    }
}
