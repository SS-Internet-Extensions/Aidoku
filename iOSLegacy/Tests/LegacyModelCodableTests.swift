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
