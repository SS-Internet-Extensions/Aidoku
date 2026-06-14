//
//  LegacyDownloadTests.swift
//  AidokuLegacyTests
//
//  Offline download manifests, download manager flow, and ZIP-page handling.
//

import XCTest
import ZIPFoundation
@testable import AidokuLegacy

final class LegacyZipPageResolverTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDown() {
        for url in tempRoots {
            try? FileManager.default.removeItem(at: url)
        }
        tempRoots = []
        super.tearDown()
    }

    /// Builds a zip containing `entries` and returns its file URL.
    private func makeArchive(_ entries: [String: Data]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipSrc-\(UUID().uuidString)", isDirectory: true)
        tempRoots.append(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in entries {
            try data.write(to: dir.appendingPathComponent(name))
        }
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Zip-\(UUID().uuidString).zip")
        tempRoots.append(zipURL)
        try FileManager.default.zipItem(at: dir, to: zipURL, shouldKeepParent: false)
        return zipURL
    }

    func testExtractEntryReturnsBytes() throws {
        let payload = Data("page-bytes".utf8)
        let zipURL = try makeArchive(["1.png": payload, "2.png": Data("other".utf8)])
        XCTAssertEqual(LegacyZipPageResolver.extractEntry(from: zipURL, filePath: "1.png"), payload)
    }

    func testExtractEntryFallsBackToBasename() throws {
        let payload = Data("nested".utf8)
        let zipURL = try makeArchive(["1.png": payload])
        // Source-supplied path may include directories the archive doesn't use.
        XCTAssertEqual(LegacyZipPageResolver.extractEntry(from: zipURL, filePath: "chapter/1.png"), payload)
    }

    func testExtractEntryReturnsNilForMissingEntry() throws {
        let zipURL = try makeArchive(["1.png": Data([0x1])])
        XCTAssertNil(LegacyZipPageResolver.extractEntry(from: zipURL, filePath: "missing.png"))
    }

    func testResolveRewritesLocalZipPageToImage() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let zipURL = try makeArchive(["p1.jpg": payload])
        let source = LegacyFixtures.source(runner: FakeLegacyRunner())
        let pages = [
            AidokuRunnerLegacyPage(content: .zipFile(url: zipURL, filePath: "p1.jpg"), hasDescription: false, description: nil),
            AidokuRunnerLegacyPage(content: .text("note"), hasDescription: false, description: nil)
        ]

        let expectation = expectation(description: "resolve")
        LegacyZipPageResolver.shared.resolve(pages, source: source) { resolved in
            XCTAssertEqual(resolved.count, 2)
            if case .image(let data) = resolved[0].content {
                XCTAssertEqual(data, payload)
            } else {
                XCTFail("zip page should resolve to image data")
            }
            if case .text = resolved[1].content {} else { XCTFail("text page should be untouched") }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testResolvePassesThroughWhenNoZipPages() {
        let source = LegacyFixtures.source(runner: FakeLegacyRunner())
        let pages = [
            AidokuRunnerLegacyPage(content: .text("a"), hasDescription: false, description: nil)
        ]
        let expectation = expectation(description: "resolve")
        LegacyZipPageResolver.shared.resolve(pages, source: source) { resolved in
            XCTAssertEqual(resolved.count, 1)
            if case .text = resolved[0].content {} else { XCTFail("page should be unchanged") }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }
}

final class LegacyDownloadTests: XCTestCase {
    private var source: AidokuRunnerLegacySource!
    private var manga: AidokuRunnerLegacyManga!
    private var chapter: AidokuRunnerLegacyChapter!

    override func setUp() {
        super.setUp()
        source = LegacyFixtures.source(runner: FakeLegacyRunner(features: .none()))
        manga = LegacyFixtures.manga(sourceKey: source.key)
        chapter = LegacyFixtures.chapter()
    }

    override func tearDown() {
        LegacyDownloadStore.shared.delete(
            sourceKey: source.key,
            mangaKey: manga.key,
            chapterKey: chapter.key
        )
        source = nil
        super.tearDown()
    }

    // MARK: - Writer + manifest round trip

    func testWriterPersistsImageAndTextPages() throws {
        let writer = try LegacyDownloadStore.shared.makeWriter(
            source: source,
            manga: manga,
            chapter: chapter,
            pageCount: 2
        )
        try writer.writeImageData(Data([0x01, 0x02, 0x03]), index: 0, description: nil)
        writer.writeText("Author note", description: "note")
        let finished = try writer.finish()

        XCTAssertEqual(finished.pageCount, 2)
        XCTAssertGreaterThan(finished.byteCount, 0)

        let store = LegacyDownloadStore.shared
        XCTAssertTrue(store.hasChapter(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key))

        let pages = try XCTUnwrap(store.pages(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key))
        XCTAssertEqual(pages.count, 2)
        if case .url = pages[0].content {} else { XCTFail("first page should be a file URL") }
        if case .text(let text) = pages[1].content {
            XCTAssertEqual(text, "Author note")
        } else {
            XCTFail("second page should be text")
        }

        XCTAssertTrue(store.downloadedChapters.contains { $0.key == finished.key })
    }

    func testDeleteRemovesDownloadedChapter() throws {
        let writer = try LegacyDownloadStore.shared.makeWriter(
            source: source,
            manga: manga,
            chapter: chapter,
            pageCount: 1
        )
        try writer.writeImageData(Data([0xFF]), index: 0, description: nil)
        let finished = try writer.finish()

        let store = LegacyDownloadStore.shared
        XCTAssertTrue(store.hasChapter(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key))
        store.delete(finished)
        XCTAssertFalse(store.hasChapter(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key))
    }

    func testWriterCancelLeavesNoChapter() throws {
        let writer = try LegacyDownloadStore.shared.makeWriter(
            source: source,
            manga: manga,
            chapter: chapter,
            pageCount: 1
        )
        try writer.writeImageData(Data([0xAA]), index: 0, description: nil)
        writer.cancel()
        XCTAssertFalse(
            LegacyDownloadStore.shared.hasChapter(sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key)
        )
    }

    // MARK: - Download manager

    func testDownloadManagerWritesInlineImageAndTextPages() {
        let runner = FakeLegacyRunner(features: .none())
        runner.pageListResult = .success([
            AidokuRunnerLegacyPage(content: .image(Data([0x10, 0x20])), hasDescription: false, description: nil),
            AidokuRunnerLegacyPage(content: .text("end note"), hasDescription: false, description: nil)
        ])
        let inlineSource = LegacyFixtures.source(runner: runner)
        let inlineManga = LegacyFixtures.manga(sourceKey: inlineSource.key)
        let inlineChapter = LegacyFixtures.chapter(key: "dm-chapter")

        let expectation = expectation(description: "download")
        LegacyDownloadManager.shared.download(
            source: inlineSource,
            manga: inlineManga,
            chapter: inlineChapter,
            progress: { _, _ in }
        ) { result in
            switch result {
                case .success(let downloaded):
                    XCTAssertEqual(downloaded.pageCount, 2)
                    XCTAssertEqual(runner.getPageListCallCount, 1)
                case .failure(let error):
                    XCTFail("expected success, got \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        LegacyDownloadStore.shared.delete(
            sourceKey: inlineSource.key,
            mangaKey: inlineManga.key,
            chapterKey: inlineChapter.key
        )
    }

    func testDownloadManagerFailsWithNoPages() {
        let runner = FakeLegacyRunner(features: .none())
        runner.pageListResult = .success([])
        let emptySource = LegacyFixtures.source(runner: runner)

        let expectation = expectation(description: "download")
        LegacyDownloadManager.shared.download(
            source: emptySource,
            manga: LegacyFixtures.manga(sourceKey: emptySource.key),
            chapter: LegacyFixtures.chapter(key: "empty-chapter"),
            progress: { _, _ in }
        ) { result in
            if case .failure = result {} else { XCTFail("expected failure for empty page list") }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testZipPageRecordsUnsupportedPlaceholder() {
        // ZIP pages are explicitly unsupported in the legacy downloader; it should
        // record a text placeholder rather than failing the whole chapter.
        let runner = FakeLegacyRunner(features: .none())
        runner.pageListResult = .success([
            AidokuRunnerLegacyPage(
                content: .zipFile(url: URL(fileURLWithPath: "/tmp/x.zip"), filePath: "1.png"),
                hasDescription: false,
                description: nil
            )
        ])
        let zipSource = LegacyFixtures.source(runner: runner)
        let zipManga = LegacyFixtures.manga(sourceKey: zipSource.key)
        let zipChapter = LegacyFixtures.chapter(key: "zip-chapter")

        let expectation = expectation(description: "download")
        LegacyDownloadManager.shared.download(
            source: zipSource,
            manga: zipManga,
            chapter: zipChapter,
            progress: { _, _ in }
        ) { result in
            if case .success(let downloaded) = result {
                XCTAssertEqual(downloaded.pageCount, 1)
            } else {
                XCTFail("expected success with placeholder page")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        let pages = LegacyDownloadStore.shared.pages(
            sourceKey: zipSource.key,
            mangaKey: zipManga.key,
            chapterKey: zipChapter.key
        )
        if case .text(let text)? = pages?.first?.content {
            XCTAssertTrue(text.contains("ZIP"))
        } else {
            XCTFail("expected text placeholder for ZIP page")
        }

        LegacyDownloadStore.shared.delete(
            sourceKey: zipSource.key,
            mangaKey: zipManga.key,
            chapterKey: zipChapter.key
        )
    }
}
