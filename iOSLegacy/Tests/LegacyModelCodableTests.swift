//
//  LegacyModelCodableTests.swift
//  AidokuLegacyTests
//
//  Codable round trips and derived properties for legacy storage models.
//

import XCTest
@testable import AidokuLegacy

final class LegacyModelCodableTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try decoder.decode(T.self, from: encoder.encode(value))
    }

    func testMangaRoundTrip() throws {
        var manga = LegacyFixtures.manga(title: "Roundtrip")
        manga.tags = ["action", "drama"]
        manga.authors = ["Author"]
        XCTAssertEqual(try roundTrip(manga), manga)
    }

    func testChapterRoundTripWithLockedDefault() throws {
        let chapter = AidokuRunnerLegacyChapter(key: "c1", title: "One", chapterNumber: 1.5, locked: true)
        let decoded = try roundTrip(chapter)
        XCTAssertEqual(decoded, chapter)
        XCTAssertTrue(decoded.locked)
    }

    func testChapterDecodesMissingLockedAsFalse() throws {
        let decoded = try decoder.decode(AidokuRunnerLegacyChapter.self, from: Data(#"{"key":"c1"}"#.utf8))
        XCTAssertFalse(decoded.locked)
    }

    func testLibraryEntryRoundTripAndKey() throws {
        let entry = LegacyLibraryEntry(
            sourceKey: "src",
            sourceName: "Src",
            manga: LegacyFixtures.manga(sourceKey: "src", key: "m"),
            dateAdded: Date(timeIntervalSince1970: 10),
            category: "Cat",
            categories: ["Cat", "Other"]
        )
        XCTAssertEqual(entry.key, "src::m")
        XCTAssertEqual(try roundTrip(entry), entry)
    }

    func testHistoryAndUpdateEntryKeys() {
        let history = LegacyHistoryEntry(
            sourceKey: "s",
            sourceName: "S",
            manga: LegacyFixtures.manga(sourceKey: "s", key: "m"),
            chapter: LegacyFixtures.chapter(key: "c"),
            pageIndex: 0,
            pageCount: 1,
            dateRead: Date()
        )
        XCTAssertEqual(history.key, "s::m::c")

        let update = LegacyUpdateEntry(
            sourceKey: "s",
            sourceName: "S",
            manga: LegacyFixtures.manga(sourceKey: "s", key: "m"),
            chapter: LegacyFixtures.chapter(key: "c"),
            dateFound: Date()
        )
        XCTAssertEqual(update.key, "s::m::c")
    }

    func testMangaMigrationCopyKeepsOriginalAndMapsState() {
        let oldSource = LegacyFixtures.source(info: LegacyFixtures.sourceInfo(id: "old.source", name: "Old Source"))
        let newSource = LegacyFixtures.source(info: LegacyFixtures.sourceInfo(id: "new.source", name: "New Source"))
        var oldManga = LegacyFixtures.manga(sourceKey: oldSource.key, key: "old-manga", title: "Old Manga")
        oldManga.chapters = [LegacyFixtures.chapter(key: "old-c1", number: 1)]
        var newManga = LegacyFixtures.manga(sourceKey: newSource.key, key: "new-manga", title: "New Manga")
        newManga.chapters = [LegacyFixtures.chapter(key: "new-c1", number: 1)]
        let dateAdded = Date(timeIntervalSince1970: 100)
        let dateRead = Date(timeIntervalSince1970: 200)
        let dateFound = Date(timeIntervalSince1970: 300)

        let library = LegacyMangaMigrationEngine.migratedLibraryEntries(
            current: [
                LegacyLibraryEntry(
                    sourceKey: oldSource.key,
                    sourceName: oldSource.name,
                    manga: oldManga,
                    dateAdded: dateAdded,
                    category: "Reading",
                    categories: ["Reading", "Favorites"]
                )
            ],
            fromSourceKey: oldSource.key,
            fromMangaKey: oldManga.key,
            toSource: newSource,
            toManga: newManga,
            keepOriginal: true,
            now: Date(timeIntervalSince1970: 400)
        )

        XCTAssertEqual(library.count, 2)
        let copiedLibrary = library.first { $0.sourceKey == newSource.key && $0.manga.key == newManga.key }
        XCTAssertEqual(copiedLibrary?.dateAdded, dateAdded)
        XCTAssertEqual(copiedLibrary?.displayCategories, ["Reading", "Favorites"])
        XCTAssertTrue(library.contains { $0.sourceKey == oldSource.key && $0.manga.key == oldManga.key })

        let history = LegacyMangaMigrationEngine.migratedHistoryEntries(
            current: [
                LegacyHistoryEntry(
                    sourceKey: oldSource.key,
                    sourceName: oldSource.name,
                    manga: oldManga,
                    chapter: oldManga.chapters![0],
                    pageIndex: 7,
                    pageCount: 10,
                    dateRead: dateRead
                )
            ],
            fromSourceKey: oldSource.key,
            fromMangaKey: oldManga.key,
            toSource: newSource,
            toManga: newManga,
            keepOriginal: true
        )
        XCTAssertEqual(history.count, 2)
        let copiedHistory = history.first { $0.sourceKey == newSource.key && $0.manga.key == newManga.key }
        XCTAssertEqual(copiedHistory?.chapter.key, "new-c1")
        XCTAssertEqual(copiedHistory?.pageIndex, 7)
        XCTAssertEqual(copiedHistory?.dateRead, dateRead)

        let updates = LegacyMangaMigrationEngine.migratedUpdateEntries(
            current: [
                LegacyUpdateEntry(
                    sourceKey: oldSource.key,
                    sourceName: oldSource.name,
                    manga: oldManga,
                    chapter: oldManga.chapters![0],
                    dateFound: dateFound
                )
            ],
            fromSourceKey: oldSource.key,
            fromMangaKey: oldManga.key,
            toSource: newSource,
            toManga: newManga,
            keepOriginal: true
        )
        XCTAssertEqual(updates.count, 2)
        let copiedUpdate = updates.first { $0.sourceKey == newSource.key && $0.manga.key == newManga.key }
        XCTAssertEqual(copiedUpdate?.chapter.key, "new-c1")
        XCTAssertEqual(copiedUpdate?.dateFound, dateFound)
    }

    func testMangaMigrationMoveRekeysTrackerEntriesAndDropsOriginal() {
        let original = LegacyTrackEntry(
            sourceKey: "old.source",
            mangaKey: "old-manga",
            trackerId: .anilist,
            remoteId: 123,
            status: .reading,
            lastReadChapter: 12,
            score: 80,
            totalChapters: 24
        )
        let staleTarget = LegacyTrackEntry(
            sourceKey: "new.source",
            mangaKey: "new-manga",
            trackerId: .anilist,
            remoteId: 999
        )
        let targetOtherTracker = LegacyTrackEntry(
            sourceKey: "new.source",
            mangaKey: "new-manga",
            trackerId: .myanimelist,
            remoteId: 777
        )
        let unrelated = LegacyTrackEntry(
            sourceKey: "other.source",
            mangaKey: "other-manga",
            trackerId: .myanimelist,
            remoteId: 456
        )

        let entries = LegacyMangaMigrationEngine.migratedTrackEntries(
            current: [original, staleTarget, targetOtherTracker, unrelated],
            fromSourceKey: "old.source",
            fromMangaKey: "old-manga",
            toSourceKey: "new.source",
            toMangaKey: "new-manga",
            keepOriginal: false
        )

        XCTAssertFalse(entries.contains { $0.sourceKey == "old.source" && $0.mangaKey == "old-manga" })
        XCTAssertTrue(entries.contains(unrelated))
        XCTAssertTrue(entries.contains(targetOtherTracker))
        let migrated = entries.first { $0.sourceKey == "new.source" && $0.mangaKey == "new-manga" }
        XCTAssertEqual(migrated?.remoteId, 123)
        XCTAssertEqual(migrated?.lastReadChapter, 12)
        XCTAssertEqual(migrated?.score, 80)
        XCTAssertEqual(
            entries.filter { $0.trackerId == .anilist && $0.sourceKey == "new.source" && $0.mangaKey == "new-manga" }.count,
            1
        )
    }

    func testDownloadedChapterRoundTripAndKey() throws {
        let chapter = LegacyDownloadedChapter(
            sourceKey: "s",
            sourceName: "S",
            manga: LegacyFixtures.manga(sourceKey: "s", key: "m"),
            chapter: LegacyFixtures.chapter(key: "c"),
            pageCount: 12,
            byteCount: 4096,
            dateDownloaded: Date(timeIntervalSince1970: 50)
        )
        XCTAssertEqual(chapter.key, "s::m::c")
        XCTAssertEqual(try roundTrip(chapter), chapter)
    }

    func testLocalChapterKindMapsEpubAsZipContainer() {
        XCTAssertEqual(LegacyLocalChapterKind.from(pathExtension: "cbz"), .cbz)
        XCTAssertEqual(LegacyLocalChapterKind.from(pathExtension: "zip"), .zip)
        XCTAssertEqual(LegacyLocalChapterKind.from(pathExtension: "epub"), .epub)
        XCTAssertEqual(LegacyLocalChapterKind.from(pathExtension: "EPUB"), .epub)
        XCTAssertEqual(LegacyLocalChapterKind.from(pathExtension: "pdf"), .pdf)

        XCTAssertTrue(LegacyLocalChapterKind.epub.isZipContainer)
        XCTAssertFalse(LegacyLocalChapterKind.pdf.isZipContainer)
    }

    // MARK: - Derived properties

    func testNormalizedListTrimsAndDeduplicatesCaseInsensitively() {
        let result = LegacyLibraryEntry.normalizedList(["  Action ", "action", "", "Drama"])
        XCTAssertEqual(result, ["Action", "Drama"])
    }

    func testDisplayCategoriesFallsBackToSingleCategory() {
        let entry = LegacyLibraryEntry(
            sourceKey: "s",
            sourceName: "S",
            manga: LegacyFixtures.manga(),
            dateAdded: Date(),
            category: "Solo",
            categories: []
        )
        XCTAssertEqual(entry.displayCategories, ["Solo"])
    }

    func testFilterGroupDetailText() {
        let group = LegacyLibraryFilterGroup(
            id: "g",
            name: "Group",
            categories: ["Reading"],
            tags: ["isekai"],
            matchAll: true
        )
        XCTAssertEqual(group.detailText, "Categories: Reading - Tags: isekai")

        let empty = LegacyLibraryFilterGroup(id: "g2", name: "Empty", categories: [], tags: [], matchAll: false)
        XCTAssertEqual(empty.detailText, "No filters")
    }

    // MARK: - Sort option

    func testSortOptionPersistence() {
        let snapshot = LegacyDefaultsSnapshot(keys: ["AidokuLegacy.library.sortOption"])
        snapshot.capture()
        defer { snapshot.restore() }

        LegacyLibrarySortOption.setCurrent(.title)
        XCTAssertEqual(LegacyLibrarySortOption.current, .title)
        XCTAssertEqual(LegacyLibrarySortOption.allCases.count, 3)
        XCTAssertEqual(LegacyLibrarySortOption.title.title, "Title")
    }
}
