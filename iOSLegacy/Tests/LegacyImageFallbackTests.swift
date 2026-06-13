//
//  LegacyImageFallbackTests.swift
//  AidokuLegacyTests
//
//  Image-request construction and cover/thumbnail fallback expansion.
//

import XCTest
@testable import AidokuLegacy

final class LegacyImageFallbackTests: XCTestCase {
    // MARK: - Base request

    func testFallbackRequestSetsImageDefaults() {
        let url = URL(string: "https://example.com/cover.jpg")!
        let request = legacyFallbackImageRequest(url: url)
        XCTAssertEqual(request.url, url)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Accept"))
        // Referer falls back to the image origin when no source is provided.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://example.com/")
    }

    func testFallbackRequestsForPlainURLHasSingleEntry() {
        let url = URL(string: "https://example.com/cover.jpg")!
        let requests = legacyFallbackImageRequests(url: url, source: nil)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, url)
    }

    func testFallbackRequestsExcludesPrimary() {
        let url = URL(string: "https://example.com/cover.jpg")!
        let primary = legacyFallbackImageRequest(url: url)
        let requests = legacyFallbackImageRequests(url: url, source: nil, excluding: primary)
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: - Request equality

    func testRequestsMatchComparesURLAndHeaders() {
        let url = URL(string: "https://example.com/cover.jpg")!
        let a = legacyFallbackImageRequest(url: url)
        let b = legacyFallbackImageRequest(url: url)
        XCTAssertTrue(legacyImageRequestsMatch(a, b))

        let other = legacyFallbackImageRequest(url: URL(string: "https://example.com/other.jpg")!)
        XCTAssertFalse(legacyImageRequestsMatch(a, other))
    }

    // MARK: - MangaDex cover fallbacks

    func testMangaDexCoverFallbacksExpandHostsAndSizes() {
        let url = URL(string: "https://uploads.mangadex.org/covers/abc-123/page.jpg")!
        let fallbacks = legacyMangaDexCoverFallbackURLs(from: url)
        XCTAssertFalse(fallbacks.isEmpty)
        XCTAssertFalse(fallbacks.contains(url)) // never duplicates the original
        XCTAssertTrue(fallbacks.contains { $0.host == "mangadex.org" })
        XCTAssertTrue(fallbacks.contains { $0.absoluteString.contains(".512.jpg") })
    }

    func testMangaDexCoverFallbacksEmptyForNonMangaDex() {
        let url = URL(string: "https://example.com/covers/abc/page.jpg")!
        XCTAssertTrue(legacyMangaDexCoverFallbackURLs(from: url).isEmpty)
    }

    // MARK: - Hitomi thumbnail fallbacks

    func testHitomiThumbnailFallbacksConvertAvifToWebpAndJpg() {
        let url = URL(string: "https://tn.hitomi.la/avifbigtn/abc/12/34.avif")!
        let fallbacks = legacyHitomiThumbnailFallbackURLs(from: url)
        XCTAssertFalse(fallbacks.isEmpty)
        XCTAssertTrue(fallbacks.contains { $0.pathExtension == "webp" })
        XCTAssertTrue(fallbacks.contains { $0.pathExtension == "jpg" })
    }

    func testHitomiThumbnailFallbacksEmptyForNonAvif() {
        let url = URL(string: "https://tn.hitomi.la/bigtn/abc/12/34.jpg")!
        XCTAssertTrue(legacyHitomiThumbnailFallbackURLs(from: url).isEmpty)
    }

    // MARK: - Path sanitization

    func testSanitizedPathComponentStripsUnsafeCharacters() {
        XCTAssertEqual(aidokuLegacySanitizedPathComponent("source/key:1"), "source_key_1")
        XCTAssertEqual(aidokuLegacySanitizedPathComponent("a.b-c_d"), "a.b-c_d")
    }

    func testSanitizedPathComponentFallsBackForEmptyResult() {
        // All characters stripped -> a non-empty UUID fallback is returned.
        XCTAssertFalse(aidokuLegacySanitizedPathComponent("///").isEmpty)
    }
}
