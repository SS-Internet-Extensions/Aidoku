//
//  LegacyModernBackupExporter.swift
//  AidokuLegacy
//
//  Exports the legacy stores into a modern Aidoku backup (JSON).
//
//  The output mirrors the modern `Backup` JSON schema (see
//  Shared/Data/Backup/Models in the main app) so a modern Aidoku install can
//  read it. Modern `Backup.load` first attempts a property-list decode and then
//  falls back to a JSON decode with the `.secondsSince1970` date strategy, so we
//  emit JSON with that same date encoding strategy.
//
//  The legacy app stores the full manga/chapter payloads inline on each row,
//  while the modern format normalises them. The exporter therefore splits the
//  legacy data back out into the modern top-level `manga` and `chapters` arrays
//  and references them by (sourceId, mangaId[, chapterId]).
//
//  iOS 12 constraints: UIKit only, no async/await — `exportBackup()` is a
//  synchronous throwing function plus a completion-based convenience wrapper.
//

import Foundation

enum LegacyModernBackupExportError: Error {
    case applicationSupportUnavailable
}

final class LegacyModernBackupExporter {
    static let shared = LegacyModernBackupExporter()

    private let encoder: JSONEncoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Modern JSON backups encode dates as seconds since 1970.
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
    }

    // Builds a modern-schema backup from the current legacy stores, writes it to
    // the legacy backups directory, and returns the file URL.
    func exportBackup() throws -> URL {
        let backup = buildBackup()
        let data = try encoder.encode(backup)
        let directory = try backupsDirectory()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        // Use the modern `aidoku_` filename prefix and `.json` extension so the
        // result is unambiguously a modern, JSON-encoded backup.
        let url = directory.appendingPathComponent("aidoku_\(formatter.string(from: Date())).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    // Completion-based convenience. Encoding/writing runs on a background queue;
    // the completion is delivered on the main queue.
    func exportBackup(completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, Error>
            do {
                let url = try self.exportBackup()
                result = .success(url)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    // MARK: - Building

    private func buildBackup() -> LegacyModernBackup {
        let libraryEntries = LegacyLibraryStore.shared.rawEntries
        let historyEntries = LegacyHistoryStore.shared.entries
        let updateEntries = LegacyUpdateStore.shared.entries

        // Collect manga and chapters from every legacy source, de-duplicated by
        // their modern composite keys.
        var mangaByKey: [String: LegacyModernBackupManga] = [:]
        var chapterByKey: [String: LegacyModernBackupChapter] = [:]
        var categoryTitles: [String] = []
        var seenCategories: Set<String> = []

        func registerManga(_ manga: AidokuRunnerLegacyManga, sourceKey: String) {
            let key = mangaKey(sourceId: sourceKey, mangaId: manga.key)
            if mangaByKey[key] == nil {
                mangaByKey[key] = modernManga(from: manga, sourceKey: sourceKey)
            }
            // Register the manga's chapters, assigning a source order.
            if let chapters = manga.chapters {
                for (index, chapter) in chapters.enumerated() {
                    registerChapter(chapter, sourceKey: sourceKey, mangaKey: manga.key, order: index)
                }
            }
        }

        func registerChapter(
            _ chapter: AidokuRunnerLegacyChapter,
            sourceKey: String,
            mangaKey mangaId: String,
            order: Int
        ) {
            let key = chapterKey(sourceId: sourceKey, mangaId: mangaId, chapterId: chapter.key)
            if chapterByKey[key] == nil {
                chapterByKey[key] = modernChapter(
                    from: chapter,
                    sourceKey: sourceKey,
                    mangaKey: mangaId,
                    order: order
                )
            }
        }

        // Library
        var library: [LegacyModernBackupLibraryManga] = []
        for entry in libraryEntries {
            registerManga(entry.manga, sourceKey: entry.sourceKey)
            let categories = entry.displayCategories
            for category in categories where !seenCategories.contains(category.lowercased()) {
                seenCategories.insert(category.lowercased())
                categoryTitles.append(category)
            }
            library.append(
                LegacyModernBackupLibraryManga(
                    lastOpened: entry.dateAdded,
                    lastUpdated: entry.dateAdded,
                    lastUpdatedChapters: entry.dateAdded,
                    lastChapter: nil,
                    lastRead: nil,
                    dateAdded: entry.dateAdded,
                    categories: categories.isEmpty ? nil : categories,
                    mangaId: entry.manga.key,
                    sourceId: entry.sourceKey
                )
            )
        }

        // History
        var history: [LegacyModernBackupHistory] = []
        for entry in historyEntries {
            registerManga(entry.manga, sourceKey: entry.sourceKey)
            registerChapter(entry.chapter, sourceKey: entry.sourceKey, mangaKey: entry.manga.key, order: 0)
            let completed = entry.pageCount > 0 && entry.pageIndex >= entry.pageCount - 1
            history.append(
                LegacyModernBackupHistory(
                    dateRead: entry.dateRead,
                    sourceId: entry.sourceKey,
                    chapterId: entry.chapter.key,
                    mangaId: entry.manga.key,
                    progress: entry.pageIndex,
                    total: entry.pageCount,
                    completed: completed
                )
            )
        }

        // Updates
        var updates: [LegacyModernBackupUpdate] = []
        for entry in updateEntries {
            registerManga(entry.manga, sourceKey: entry.sourceKey)
            registerChapter(entry.chapter, sourceKey: entry.sourceKey, mangaKey: entry.manga.key, order: 0)
            updates.append(
                LegacyModernBackupUpdate(
                    date: entry.dateFound,
                    viewed: false,
                    sourceId: entry.sourceKey,
                    mangaId: entry.manga.key,
                    chapterId: entry.chapter.key
                )
            )
        }

        let sourceLists = LegacySourceRepositoryStore.shared.repositoryURLs.map { $0.absoluteString }
        let sourceIds = Set(mangaByKey.values.map { $0.sourceId }).sorted()

        return LegacyModernBackup(
            library: library,
            history: history,
            manga: Array(mangaByKey.values),
            chapters: Array(chapterByKey.values),
            updates: updates,
            categories: categoryTitles.map { LegacyModernBackupCategory(title: $0) },
            sources: sourceIds.map { LegacyModernBackupSource(id: $0) },
            sourceLists: sourceLists.isEmpty ? nil : sourceLists,
            date: Date(),
            name: "AidokuLegacy",
            automatic: false,
            version: "AidokuLegacy"
        )
    }

    // MARK: - Mapping

    private func modernManga(
        from manga: AidokuRunnerLegacyManga,
        sourceKey: String
    ) -> LegacyModernBackupManga {
        return LegacyModernBackupManga(
            id: manga.key,
            sourceId: sourceKey,
            title: manga.title,
            author: manga.authors?.joined(separator: ", "),
            artist: manga.artists?.joined(separator: ", "),
            desc: manga.description,
            tags: manga.tags,
            cover: manga.cover,
            url: manga.url?.absoluteString,
            status: 0,
            nsfw: 0,
            viewer: 0,
            nextUpdateTime: nil,
            chapterFlags: nil,
            langFilter: nil,
            scanlatorFilter: nil
        )
    }

    private func modernChapter(
        from chapter: AidokuRunnerLegacyChapter,
        sourceKey: String,
        mangaKey: String,
        order: Int
    ) -> LegacyModernBackupChapter {
        return LegacyModernBackupChapter(
            sourceId: sourceKey,
            mangaId: mangaKey,
            id: chapter.key,
            title: chapter.title,
            scanlator: chapter.scanlators?.joined(separator: ", "),
            url: chapter.url?.absoluteString,
            lang: chapter.language ?? "en",
            chapter: chapter.chapterNumber,
            volume: chapter.volumeNumber,
            dateUploaded: chapter.dateUploaded,
            thumbnail: chapter.thumbnail,
            locked: chapter.locked,
            sourceOrder: order
        )
    }

    // MARK: - Keys

    private func mangaKey(sourceId: String, mangaId: String) -> String {
        return "\(sourceId)::\(mangaId)"
    }

    private func chapterKey(sourceId: String, mangaId: String, chapterId: String) -> String {
        return "\(sourceId)::\(mangaId)::\(chapterId)"
    }

    // MARK: - Directory

    // Mirrors the legacy backups directory used by `LegacyBackupManager` so
    // exported modern backups sit alongside native legacy backups.
    private func backupsDirectory() throws -> URL {
        guard
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            throw LegacyModernBackupExportError.applicationSupportUnavailable
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: nil)
        let directory = support.appendingPathComponent("AidokuLegacyBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }
}
