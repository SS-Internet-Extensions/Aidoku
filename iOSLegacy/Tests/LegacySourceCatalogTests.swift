//
//  LegacySourceCatalogTests.swift
//  AidokuLegacyTests
//
//  Source-list decoding, URL resolution, and repository normalization.
//

import XCTest
@testable import AidokuLegacy

final class LegacySourceCatalogTests: XCTestCase {
    private let repositoryURL = URL(string: "https://aidoku-community.github.io/sources/index.min.json")!

    // MARK: - Source info decoding

    func testDecodesModernSourceFields() throws {
        let json = """
        {
          "id": "multi.mangadex",
          "name": "MangaDex",
          "version": 42,
          "iconURL": "icons/mangadex.png",
          "downloadURL": "sources/multi.mangadex.aix",
          "languages": ["en", "ja"],
          "contentRating": 1,
          "altNames": ["MD"],
          "baseURL": "https://mangadex.org"
        }
        """
        let source = try JSONDecoder()
            .decode(LegacySourceInfo.self, from: Data(json.utf8))
            .with(repositoryURL: repositoryURL)

        XCTAssertEqual(source.id, "multi.mangadex")
        XCTAssertEqual(source.version, 42)
        XCTAssertEqual(source.resolvedLanguages, ["en", "ja"])
        XCTAssertEqual(source.languageText, "en, ja")
        XCTAssertEqual(source.ratingText, "Suggestive")
        XCTAssertEqual(source.resolvedBaseURL, URL(string: "https://mangadex.org"))
        XCTAssertEqual(
            source.resolvedDownloadURL,
            URL(string: "https://aidoku-community.github.io/sources/multi.mangadex.aix")
        )
        XCTAssertEqual(
            source.resolvedIconURL,
            URL(string: "https://aidoku-community.github.io/icons/mangadex.png")
        )
    }

    func testDecodesLegacyFlatSourceFields() throws {
        // Older list format using `lang`, `nsfw`, `file`, `icon`.
        let json = """
        {
          "id": "en.legacy",
          "name": "Legacy Source",
          "version": 3,
          "lang": "en",
          "nsfw": 2,
          "file": "en.legacy.aix",
          "icon": "legacy.png"
        }
        """
        let source = try JSONDecoder()
            .decode(LegacySourceInfo.self, from: Data(json.utf8))
            .with(repositoryURL: repositoryURL)

        XCTAssertEqual(source.resolvedLanguages, ["en"])
        XCTAssertEqual(source.ratingText, "NSFW")
        XCTAssertEqual(
            source.resolvedDownloadURL,
            URL(string: "https://aidoku-community.github.io/sources/en.legacy.aix")
        )
        XCTAssertEqual(
            source.resolvedIconURL,
            URL(string: "https://aidoku-community.github.io/icons/legacy.png")
        )
    }

    func testResolvedURLsAreNilWithoutRepository() throws {
        let json = """
        { "id": "x", "name": "X", "version": 1, "downloadURL": "sources/x.aix" }
        """
        let source = try JSONDecoder().decode(LegacySourceInfo.self, from: Data(json.utf8))
        XCTAssertNil(source.resolvedDownloadURL)
        XCTAssertNil(source.resolvedIconURL)
    }

    func testLanguageTextFallsBackToMulti() throws {
        let json = """
        { "id": "x", "name": "X", "version": 1 }
        """
        let source = try JSONDecoder().decode(LegacySourceInfo.self, from: Data(json.utf8))
        XCTAssertEqual(source.languageText, "multi")
        XCTAssertEqual(source.ratingText, "Safe")
    }

    // MARK: - Search matching

    func testMatchesQueryByNameIDLanguageAndAltNames() throws {
        let json = """
        {
          "id": "en.example",
          "name": "Example Reader",
          "version": 1,
          "languages": ["en"],
          "altNames": ["ExRdr"]
        }
        """
        let source = try JSONDecoder().decode(LegacySourceInfo.self, from: Data(json.utf8))

        XCTAssertTrue(source.matches(query: ""))           // empty matches all
        XCTAssertTrue(source.matches(query: "example"))    // name
        XCTAssertTrue(source.matches(query: "EN.EX"))      // id, case-insensitive
        XCTAssertTrue(source.matches(query: "en"))         // language
        XCTAssertTrue(source.matches(query: "exrdr"))      // alt name
        XCTAssertFalse(source.matches(query: "nonexistent"))
    }

    // MARK: - Repository normalization

    func testNormalizedURLPassesThroughJSON() {
        let store = LegacySourceRepositoryStore.shared
        XCTAssertEqual(
            store.normalizedURL(from: "https://example.com/list.json"),
            URL(string: "https://example.com/list.json")
        )
    }

    func testNormalizedURLAppendsIndexForBareDomain() {
        let store = LegacySourceRepositoryStore.shared
        XCTAssertEqual(
            store.normalizedURL(from: "example.com/repo"),
            URL(string: "https://example.com/repo/index.min.json")
        )
    }

    func testNormalizedURLExpandsGitHubRepo() {
        let store = LegacySourceRepositoryStore.shared
        XCTAssertEqual(
            store.normalizedURL(from: "https://github.com/owner/repo"),
            URL(string: "https://raw.githubusercontent.com/owner/repo/main/index.min.json")
        )
    }

    func testNormalizedURLRejectsEmptyInput() {
        let store = LegacySourceRepositoryStore.shared
        XCTAssertNil(store.normalizedURL(from: "   "))
    }

    // MARK: - Update result

    func testUpdateResultSkippedFlag() {
        let result = LegacySourceUpdateResult(
            checkedCount: 0,
            updatedCount: 0,
            failedCount: 0,
            skipped: true,
            error: nil
        )
        XCTAssertTrue(result.skipped)
        XCTAssertEqual(result.updatedCount, 0)
    }
}
