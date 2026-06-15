//
//  LegacyNetURLTests.swift
//  AidokuLegacyTests
//
//  Lenient URL parsing for the legacy WASM net layer (iOS 12 strict parser).
//

import XCTest
@testable import AidokuLegacy

final class LegacyNetURLTests: XCTestCase {
    func testPlainURLParsesUnchanged() {
        let string = "https://api.mangadex.org/manga?limit=20"
        XCTAssertEqual(Net.lenientURL(from: string)?.absoluteString, string)
    }

    func testBracketQueryParamsAreEncoded() {
        // MangaDex builds query strings with literal brackets, which iOS 12's
        // strict URL(string:) rejects. They must be percent-encoded instead.
        let string = "https://api.mangadex.org/manga?includes[]=cover_art&order[updatedAt]=desc"
        let url = Net.lenientURL(from: string)
        XCTAssertNotNil(url)
        XCTAssertEqual(
            url?.absoluteString,
            "https://api.mangadex.org/manga?includes%5B%5D=cover_art&order%5BupdatedAt%5D=desc"
        )
    }

    func testExistingPercentEscapesNotDoubleEncoded() {
        let string = "https://api.mangadex.org/manga?title=hello%20world&includes[]=author"
        let url = Net.lenientURL(from: string)
        XCTAssertEqual(
            url?.absoluteString,
            "https://api.mangadex.org/manga?title=hello%20world&includes%5B%5D=author"
        )
    }
}
