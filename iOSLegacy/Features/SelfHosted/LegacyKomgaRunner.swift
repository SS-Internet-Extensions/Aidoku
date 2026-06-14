//
//  LegacyKomgaRunner.swift
//  AidokuLegacy
//
//  An AidokuRunnerLegacyRunner that serves a single self-hosted (Komga) book as
//  reader pages, so server books can be opened with the existing reader without a
//  WASM source. Pages are plain authenticated URLs; the Basic-auth header is
//  attached through getImageRequest (providesImageRequests = true), which the
//  reader already honours for every .url page.
//
//  Only page listing + image requests are implemented; every other capability is
//  disabled, mirroring LegacyLocalFileRunner.
//

import Foundation
import UIKit

final class LegacyKomgaRunner: AidokuRunnerLegacyRunner {
    private let server: LegacyKomgaServer
    private let book: LegacyKomgaBook
    private let client: LegacyKomgaClient

    let features = AidokuRunnerLegacySourceFeatures(
        providesListings: false,
        providesHome: false,
        dynamicFilters: false,
        dynamicSettings: false,
        dynamicListings: false,
        processesPages: false,
        providesImageRequests: true,
        providesPageDescriptions: false,
        providesAlternateCovers: false,
        providesBaseUrl: false,
        handlesNotifications: false,
        handlesDeepLinks: false,
        handlesBasicLogin: false,
        handlesWebLogin: false,
        handlesMigration: false
    )

    init(server: LegacyKomgaServer, book: LegacyKomgaBook) {
        self.server = server
        self.book = book
        self.client = LegacyKomgaClient(server: server)
    }

    // HTTP Basic header value for the server credentials, or nil if it cannot be built.
    private var basicAuthValue: String? {
        let raw = "\(server.username):\(server.password)"
        guard let encoded = raw.data(using: .utf8)?.base64EncodedString() else { return nil }
        return "Basic \(encoded)"
    }

    func getPageList(
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        completion: @escaping (Result<[AidokuRunnerLegacyPage], Error>) -> Void
    ) {
        guard book.pageCount > 0 else {
            completion(.failure(LegacyKomgaError.invalidResponse))
            return
        }
        var pages: [AidokuRunnerLegacyPage] = []
        // Komga page indices are 1-based.
        for page in 1...book.pageCount {
            guard let url = client.pageImageURL(bookId: book.id, page: page) else { continue }
            pages.append(
                AidokuRunnerLegacyPage(
                    content: .url(url, context: nil),
                    hasDescription: false,
                    description: nil
                )
            )
        }
        guard !pages.isEmpty else {
            completion(.failure(LegacyKomgaError.invalidResponse))
            return
        }
        completion(.success(pages))
    }

    func getImageRequest(
        url: URL,
        context: [String: String]?,
        completion: @escaping (Result<AidokuRunnerLegacyImageRequest, Error>) -> Void
    ) {
        var headers = ["Accept": "image/*"]
        if let basicAuthValue = basicAuthValue {
            headers["Authorization"] = basicAuthValue
        }
        completion(.success(
            AidokuRunnerLegacyImageRequest(url: url, method: "GET", headers: headers, body: nil)
        ))
    }

    // MARK: - Unsupported capabilities

    func getSearchMangaList(
        query: String?,
        page: Int,
        filters: [AidokuRunnerLegacyFilterValue],
        completion: @escaping (Result<AidokuRunnerLegacyMangaPageResult, Error>) -> Void
    ) {
        completion(.failure(AidokuRunnerLegacyError.backendUnavailable))
    }

    func getMangaList(
        listing: AidokuRunnerLegacyListing,
        page: Int,
        completion: @escaping (Result<AidokuRunnerLegacyMangaPageResult, Error>) -> Void
    ) {
        completion(.failure(AidokuRunnerLegacyError.backendUnavailable))
    }

    func getListings(completion: @escaping (Result<[AidokuRunnerLegacyListing], Error>) -> Void) {
        completion(.success([]))
    }

    func getHome(completion: @escaping (Result<AidokuRunnerLegacyHome, Error>) -> Void) {
        completion(.failure(AidokuRunnerLegacyError.backendUnavailable))
    }

    func getFilters(completion: @escaping (Result<[AidokuRunnerLegacyFilter], Error>) -> Void) {
        completion(.success([]))
    }

    func getSettings(completion: @escaping (Result<[AidokuRunnerLegacySettingItem], Error>) -> Void) {
        completion(.success([]))
    }

    func getMangaUpdate(
        manga: AidokuRunnerLegacyManga,
        needsDetails: Bool,
        needsChapters: Bool,
        completion: @escaping (Result<AidokuRunnerLegacyManga, Error>) -> Void
    ) {
        completion(.success(manga))
    }

    func processPageImage(
        data: Data,
        response: HTTPURLResponse,
        request: URLRequest,
        context: [String: String]?,
        completion: @escaping (Result<UIImage?, Error>) -> Void
    ) {
        completion(.failure(AidokuRunnerLegacyError.backendUnavailable))
    }

    func getPageDescription(
        page: AidokuRunnerLegacyPage,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        completion(.success(nil))
    }

    func getAlternateCovers(
        manga: AidokuRunnerLegacyManga,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        completion(.success([]))
    }

    func getBaseUrl(completion: @escaping (Result<URL?, Error>) -> Void) {
        completion(.success(server.url))
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
