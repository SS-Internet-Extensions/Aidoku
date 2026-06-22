//
//  LegacyBackupRestoreTests.swift
//  AidokuLegacyTests
//
//  Legacy JSON backup export/import round trip.
//

import XCTest
@testable import AidokuLegacy

final class LegacyBackupRestoreTests: XCTestCase {
    private let settingKey = "AidokuLegacy.test.backupFlag"
    private var snapshot: LegacyDefaultsSnapshot!
    private var createdBackupURL: URL?

    override func setUp() {
        super.setUp()
        snapshot = LegacyDefaultsSnapshot(keys: [
            "AidokuLegacy.library.entries",
            "AidokuLegacy.history.entries",
            "AidokuLegacy.updates.entries",
            "AidokuLegacy.tracker.entries",
            "AidokuLegacy.library.filterGroups",
            "AidokuLegacy.sourceRepositories",
            "AidokuLegacy.reader.maxImageHeight",
            "AidokuLegacy.reader.prefetchPages",
            "AidokuLegacy.reader.showPageNumber",
            "src.a.language",
            "src.a.login.password",
            settingKey
        ])
        snapshot.capture()
    }

    override func tearDown() {
        if let url = createdBackupURL {
            try? FileManager.default.removeItem(at: url)
        }
        snapshot.restore()
        super.tearDown()
    }

    func testBackupRestoreRoundTripPreservesLibraryHistoryUpdatesAndSettings() throws {
        // Seed known state.
        let entry = LegacyLibraryEntry(
            sourceKey: "src.a",
            sourceName: "Source A",
            manga: LegacyFixtures.manga(sourceKey: "src.a", key: "m1", title: "Alpha"),
            dateAdded: Date(timeIntervalSince1970: 1_000),
            category: "Reading",
            categories: ["Reading"]
        )
        LegacyLibraryStore.shared.replace([entry])

        let history = LegacyHistoryEntry(
            sourceKey: "src.a",
            sourceName: "Source A",
            manga: LegacyFixtures.manga(sourceKey: "src.a", key: "m1", title: "Alpha"),
            chapter: LegacyFixtures.chapter(key: "c1"),
            pageIndex: 3,
            pageCount: 20,
            dateRead: Date(timeIntervalSince1970: 2_000)
        )
        LegacyHistoryStore.shared.replace([history])

        let update = LegacyUpdateEntry(
            sourceKey: "src.a",
            sourceName: "Source A",
            manga: LegacyFixtures.manga(sourceKey: "src.a", key: "m1", title: "Alpha"),
            chapter: LegacyFixtures.chapter(key: "c2"),
            dateFound: Date(timeIntervalSince1970: 3_000)
        )
        LegacyUpdateStore.shared.replace([update])

        UserDefaults.standard.set(true, forKey: settingKey)

        // Export.
        let url = try LegacyBackupManager.shared.createBackup()
        createdBackupURL = url
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Mutate away from the backed-up state.
        LegacyLibraryStore.shared.replace([])
        LegacyHistoryStore.shared.replace([])
        LegacyUpdateStore.shared.replace([])
        UserDefaults.standard.set(false, forKey: settingKey)

        // Import.
        try LegacyBackupManager.shared.restore(from: url)

        XCTAssertEqual(LegacyLibraryStore.shared.rawEntries.map { $0.key }, ["src.a::m1"])
        XCTAssertEqual(LegacyLibraryStore.shared.rawEntries.first?.manga.title, "Alpha")
        XCTAssertEqual(LegacyHistoryStore.shared.entries.map { $0.key }, ["src.a::m1::c1"])
        XCTAssertEqual(LegacyHistoryStore.shared.entries.first?.pageIndex, 3)
        XCTAssertEqual(LegacyUpdateStore.shared.entries.map { $0.key }, ["src.a::m1::c2"])
        XCTAssertTrue(UserDefaults.standard.bool(forKey: settingKey))
    }

    func testBackupURLsListsCreatedBackup() throws {
        LegacyLibraryStore.shared.replace([])
        let url = try LegacyBackupManager.shared.createBackup()
        createdBackupURL = url
        XCTAssertTrue(LegacyBackupManager.shared.backupURLs().contains(url))
    }

    func testModernBackupExportMapsTrackItemsReadingSessionsSettingsAndMangaFlags() throws {
        let manga = AidokuRunnerLegacyManga(
            sourceKey: "src.a",
            key: "m1",
            title: "Alpha",
            cover: nil,
            artists: nil,
            authors: nil,
            description: nil,
            url: nil,
            tags: nil,
            status: .completed,
            contentRating: .nsfw,
            viewer: .rightToLeft,
            updateStrategy: .never,
            nextUpdateTime: 4_000,
            chapters: [LegacyFixtures.chapter(key: "c1")]
        )
        LegacyLibraryStore.shared.replace([
            LegacyLibraryEntry(
                sourceKey: "src.a",
                sourceName: "Source A",
                manga: manga,
                dateAdded: Date(timeIntervalSince1970: 1_000),
                category: "Reading",
                categories: ["Reading"]
            )
        ])
        LegacyHistoryStore.shared.replace([
            LegacyHistoryEntry(
                sourceKey: "src.a",
                sourceName: "Source A",
                manga: manga,
                chapter: LegacyFixtures.chapter(key: "c1"),
                pageIndex: 4,
                pageCount: 20,
                dateRead: Date(timeIntervalSince1970: 2_000)
            )
        ])
        LegacyUpdateStore.shared.replace([])
        LegacyTrackerStore.shared.replace([
            LegacyTrackEntry(
                sourceKey: "src.a",
                mangaKey: "m1",
                trackerId: .anilist,
                remoteId: 123,
                lastReadChapter: 7
            )
        ])
        UserDefaults.standard.set(1800, forKey: "AidokuLegacy.reader.maxImageHeight")
        UserDefaults.standard.set("en", forKey: "src.a.language")
        UserDefaults.standard.set("do-not-export", forKey: "src.a.login.password")

        let url = try LegacyModernBackupExporter.shared.exportBackup()
        createdBackupURL = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let backup = try decoder.decode(LegacyModernBackup.self, from: Data(contentsOf: url))

        XCTAssertEqual(backup.trackItems?.first?.id, "123")
        XCTAssertEqual(backup.trackItems?.first?.trackerId, "anilist")
        XCTAssertEqual(backup.trackItems?.first?.chapterOffset, 7)
        XCTAssertEqual(backup.readingSessions?.first?.pagesRead, 5)
        XCTAssertEqual(backup.settings?["AidokuLegacy.reader.maxImageHeight"]?.rawValue as? Int, 1800)
        XCTAssertEqual(backup.settings?["src.a.language"]?.rawValue as? String, "en")
        XCTAssertNil(backup.settings?["src.a.login.password"])
        XCTAssertEqual(backup.manga?.first?.status, Int(PublishingStatus.completed.rawValue))
        XCTAssertEqual(backup.manga?.first?.nsfw, Int(ContentRating.nsfw.rawValue))
        XCTAssertEqual(backup.manga?.first?.viewer, Int(Viewer.rightToLeft.rawValue))
    }

    func testModernBackupImportMapsTrackItemsReadingSessionsSettingsAndMangaFlags() throws {
        let backup = LegacyModernBackup(
            library: [
                LegacyModernBackupLibraryManga(
                    dateAdded: Date(timeIntervalSince1970: 1_000),
                    categories: ["Reading"],
                    mangaId: "m1",
                    sourceId: "src.a"
                )
            ],
            history: nil,
            manga: [
                LegacyModernBackupManga(
                    id: "m1",
                    sourceId: "src.a",
                    title: "Alpha",
                    status: Int(PublishingStatus.completed.rawValue),
                    nsfw: Int(ContentRating.suggestive.rawValue),
                    viewer: Int(Viewer.webtoon.rawValue)
                )
            ],
            chapters: [
                LegacyModernBackupChapter(
                    sourceId: "src.a",
                    mangaId: "m1",
                    id: "c1",
                    title: "Chapter 1",
                    lang: "en",
                    sourceOrder: 0
                )
            ],
            trackItems: [
                LegacyModernBackupTrackItem(
                    id: "456",
                    trackerId: "myanimelist",
                    mangaId: "m1",
                    sourceId: "src.a",
                    title: "Alpha",
                    chapterOffset: 8
                )
            ],
            readingSessions: [
                LegacyModernBackupReadingSession(
                    pagesRead: 6,
                    startDate: Date(timeIntervalSince1970: 2_000),
                    endDate: Date(timeIntervalSince1970: 2_060),
                    sourceId: "src.a",
                    mangaId: "m1",
                    chapterId: "c1"
                )
            ],
            settings: [
                "AidokuLegacy.reader.prefetchPages": .int(4),
                "AidokuLegacy.reader.showPageNumber": .bool(false),
                "src.a.language": .string("en")
            ],
            date: Date(timeIntervalSince1970: 3_000),
            version: "test"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyModernBackup-\(UUID().uuidString).json")
        try encoder.encode(backup).write(to: url, options: .atomic)
        createdBackupURL = url

        LegacyLibraryStore.shared.replace([])
        LegacyHistoryStore.shared.replace([])
        LegacyUpdateStore.shared.replace([])
        LegacyTrackerStore.shared.replace([])
        UserDefaults.standard.removeObject(forKey: "AidokuLegacy.reader.prefetchPages")
        UserDefaults.standard.set(true, forKey: "AidokuLegacy.reader.showPageNumber")

        let result = try LegacyModernBackupImporter.shared.importBackup(at: url, merge: false)

        XCTAssertEqual(result.libraryAdded, 1)
        XCTAssertEqual(result.historyAdded, 1)
        XCTAssertEqual(LegacyLibraryStore.shared.rawEntries.first?.manga.viewer, .webtoon)
        XCTAssertEqual(LegacyLibraryStore.shared.rawEntries.first?.manga.status, .completed)
        XCTAssertEqual(LegacyLibraryStore.shared.rawEntries.first?.manga.contentRating, .suggestive)
        XCTAssertEqual(LegacyHistoryStore.shared.entries.first?.key, "src.a::m1::c1")
        XCTAssertEqual(LegacyHistoryStore.shared.entries.first?.pageIndex, 5)
        XCTAssertEqual(LegacyTrackerStore.shared.entries.first?.remoteId, 456)
        XCTAssertEqual(LegacyTrackerStore.shared.entries.first?.trackerId, .myanimelist)
        XCTAssertEqual(LegacyTrackerStore.shared.entries.first?.lastReadChapter, 8)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "AidokuLegacy.reader.prefetchPages"), 4)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "AidokuLegacy.reader.showPageNumber"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: "src.a.language"), "en")
    }
}
