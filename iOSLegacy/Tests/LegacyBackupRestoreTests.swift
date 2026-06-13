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
            "AidokuLegacy.library.filterGroups",
            "AidokuLegacy.sourceRepositories",
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
}
