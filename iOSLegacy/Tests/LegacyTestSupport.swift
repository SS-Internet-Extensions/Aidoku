//
//  LegacyTestSupport.swift
//  AidokuLegacyTests
//
//  Shared fakes and builders for the iOS 12 legacy test suite.
//

import Foundation
import UIKit
@testable import AidokuLegacy

// MARK: - Feature helpers

extension AidokuRunnerLegacySourceFeatures {
    /// All features disabled. Override individual flags as needed in a test.
    static func none() -> AidokuRunnerLegacySourceFeatures {
        AidokuRunnerLegacySourceFeatures(
            providesListings: false,
            providesHome: false,
            dynamicFilters: false,
            dynamicSettings: false,
            dynamicListings: false,
            processesPages: false,
            providesImageRequests: false,
            providesPageDescriptions: false,
            providesAlternateCovers: false,
            providesBaseUrl: false,
            handlesNotifications: false,
            handlesDeepLinks: false,
            handlesBasicLogin: false,
            handlesWebLogin: false,
            handlesMigration: false
        )
    }
}

// MARK: - Fake runner

/// A configurable `AidokuRunnerLegacyRunner` for exercising the source facade and
/// download paths without any WASM backend or network access.
final class FakeLegacyRunner: AidokuRunnerLegacyRunner {
    var features: AidokuRunnerLegacySourceFeatures

    var pageListResult: Result<[AidokuRunnerLegacyPage], Error> = .success([])
    var imageRequestResult: Result<AidokuRunnerLegacyImageRequest, Error> = .failure(AidokuRunnerLegacyError.backendUnavailable)
    var settingsResult: Result<[AidokuRunnerLegacySettingItem], Error> = .success([])
    var searchResult: Result<AidokuRunnerLegacyMangaPageResult, Error> = .success(
        AidokuRunnerLegacyMangaPageResult(entries: [], hasNextPage: false)
    )
    var pageDescriptionResult: Result<String?, Error> = .success(nil)

    private(set) var getPageListCallCount = 0
    private(set) var getImageRequestCallCount = 0
    private(set) var getSettingsCallCount = 0
    private(set) var getSearchMangaListCallCount = 0

    init(features: AidokuRunnerLegacySourceFeatures = .none()) {
        self.features = features
    }

    func getSearchMangaList(
        query: String?,
        page: Int,
        filters: [AidokuRunnerLegacyFilterValue],
        completion: @escaping (Result<AidokuRunnerLegacyMangaPageResult, Error>) -> Void
    ) {
        getSearchMangaListCallCount += 1
        completion(searchResult)
    }

    func getMangaList(
        listing: AidokuRunnerLegacyListing,
        page: Int,
        completion: @escaping (Result<AidokuRunnerLegacyMangaPageResult, Error>) -> Void
    ) {
        completion(searchResult)
    }

    func getListings(completion: @escaping (Result<[AidokuRunnerLegacyListing], Error>) -> Void) {
        completion(.success([]))
    }

    func getHome(completion: @escaping (Result<AidokuRunnerLegacyHome, Error>) -> Void) {
        completion(.success(AidokuRunnerLegacyHome(components: [])))
    }

    func getFilters(completion: @escaping (Result<[AidokuRunnerLegacyFilter], Error>) -> Void) {
        completion(.success([]))
    }

    func getSettings(completion: @escaping (Result<[AidokuRunnerLegacySettingItem], Error>) -> Void) {
        getSettingsCallCount += 1
        completion(settingsResult)
    }

    func getMangaUpdate(
        manga: AidokuRunnerLegacyManga,
        needsDetails: Bool,
        needsChapters: Bool,
        completion: @escaping (Result<AidokuRunnerLegacyManga, Error>) -> Void
    ) {
        completion(.success(manga))
    }

    func getPageList(
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        completion: @escaping (Result<[AidokuRunnerLegacyPage], Error>) -> Void
    ) {
        getPageListCallCount += 1
        completion(pageListResult)
    }

    func getImageRequest(
        url: URL,
        context: [String: String]?,
        completion: @escaping (Result<AidokuRunnerLegacyImageRequest, Error>) -> Void
    ) {
        getImageRequestCallCount += 1
        completion(imageRequestResult)
    }

    func processPageImage(
        data: Data,
        response: HTTPURLResponse,
        request: URLRequest,
        context: [String: String]?,
        completion: @escaping (Result<UIImage?, Error>) -> Void
    ) {
        completion(.success(nil))
    }

    func getPageDescription(
        page: AidokuRunnerLegacyPage,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        completion(pageDescriptionResult)
    }

    func getAlternateCovers(
        manga: AidokuRunnerLegacyManga,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        completion(.success([]))
    }

    func getBaseUrl(completion: @escaping (Result<URL?, Error>) -> Void) {
        completion(.success(nil))
    }

    func handleNotification(notification: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }

    func handleBasicLogin(
        key: String,
        username: String,
        password: String,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        completion(.success(true))
    }

    func handleWebLogin(
        key: String,
        cookies: [String: String],
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        completion(.success(true))
    }
}

/// Backend factory that always hands back a provided fake runner, so package
/// install tests never touch the WASM backend.
struct FakeLegacyBackendFactory: AidokuRunnerLegacyBackendFactory {
    let runner: AidokuRunnerLegacyRunner

    init(runner: AidokuRunnerLegacyRunner = FakeLegacyRunner()) {
        self.runner = runner
    }

    func makeRunner(
        sourceURL: URL,
        info: AidokuRunnerLegacySourceInfo
    ) throws -> AidokuRunnerLegacyRunner {
        runner
    }
}

// MARK: - Model builders

enum LegacyFixtures {
    static func sourceInfo(
        id: String = "test.source",
        name: String = "Test Source",
        version: Int = 1,
        languages: [String] = ["en"],
        contentRating: AidokuRunnerLegacySourceContentRating = .safe,
        urls: [String]? = nil
    ) -> AidokuRunnerLegacySourceInfo {
        AidokuRunnerLegacySourceInfo(
            info: .init(
                id: id,
                name: name,
                altNames: nil,
                version: version,
                url: urls?.first,
                urls: urls,
                contentRating: contentRating,
                languages: languages,
                minAppVersion: nil,
                maxAppVersion: nil
            ),
            listings: nil,
            config: nil
        )
    }

    /// JSON `source.json` payload matching `AidokuRunnerLegacySourceInfo`.
    static func sourceJSON(
        id: String = "test.source",
        name: String = "Test Source",
        version: Int = 1,
        languages: [String] = ["en"]
    ) -> Data {
        let languageList = languages.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
        {
          "info": {
            "id": "\(id)",
            "name": "\(name)",
            "version": \(version),
            "languages": [\(languageList)],
            "contentRating": 0
          }
        }
        """
        return Data(json.utf8)
    }

    static func manga(
        sourceKey: String = "test.source",
        key: String = "manga-1",
        title: String = "Test Manga"
    ) -> AidokuRunnerLegacyManga {
        AidokuRunnerLegacyManga(
            sourceKey: sourceKey,
            key: key,
            title: title,
            cover: nil,
            artists: nil,
            authors: nil,
            description: nil,
            url: nil,
            tags: nil,
            chapters: nil
        )
    }

    static func chapter(key: String = "chapter-1", number: Float = 1) -> AidokuRunnerLegacyChapter {
        AidokuRunnerLegacyChapter(key: key, title: "Chapter \(number)", chapterNumber: number)
    }

    /// Builds an in-process source backed by a fake runner. The `url` is a fresh
    /// temporary directory, so the facade's optional filters/settings/icon files
    /// are simply absent.
    static func source(
        info: AidokuRunnerLegacySourceInfo? = nil,
        runner: AidokuRunnerLegacyRunner = FakeLegacyRunner()
    ) -> AidokuRunnerLegacySource {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyTestSource-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AidokuRunnerLegacySource(
            url: directory,
            info: info ?? sourceInfo(),
            runner: runner
        )
    }
}

// MARK: - UserDefaults isolation

/// Snapshots a set of UserDefaults keys so a test that writes global defaults can
/// restore them afterwards, keeping the suite order-independent.
final class LegacyDefaultsSnapshot {
    private let keys: [String]
    private var saved: [String: Any?] = [:]

    init(keys: [String]) {
        self.keys = keys
    }

    func capture() {
        saved = [:]
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
        }
    }

    func restore() {
        for key in keys {
            if let value = saved[key], let value = value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
