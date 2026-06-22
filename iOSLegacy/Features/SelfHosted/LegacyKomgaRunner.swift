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

    func getPageList(
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        completion: @escaping (Result<[AidokuRunnerLegacyPage], Error>) -> Void
    ) {
        if server.kind == .opds, let downloadURL = book.downloadURL {
            downloadOPDSBook(url: downloadURL, manga: manga, chapter: chapter, completion: completion)
            return
        }

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
        client.imageHeaders { result in
            switch result {
                case .success(let headers):
                    completion(.success(
                        AidokuRunnerLegacyImageRequest(url: url, method: "GET", headers: headers, body: nil)
                    ))
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    private func downloadOPDSBook(
        url: URL,
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        completion: @escaping (Result<[AidokuRunnerLegacyPage], Error>) -> Void
    ) {
        let kind = book.acquisitionKind
            ?? LegacyKomgaClient.opdsAcquisitionKind(url: url, type: nil)
            ?? LegacyLocalChapterKind.from(pathExtension: url.pathExtension)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if !server.username.isEmpty || !server.password.isEmpty {
            let raw = "\(server.username):\(server.password)"
            if let encoded = raw.data(using: .utf8)?.base64EncodedString() {
                request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
            }
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
                DispatchQueue.main.async {
                    completion(.failure(LegacyKomgaError.requestFailed(
                        String(
                            format: LegacyString("self_hosted.error.status_code"),
                            httpResponse.statusCode
                        )
                    )))
                }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(LegacyKomgaError.invalidResponse))
                }
                return
            }

            let fileURL = self.opdsArchiveURL(kind: kind)
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            let pages = LegacyLocalFilePageProvider.pages(
                archiveURL: fileURL,
                kind: kind,
                mangaId: manga.key,
                chapterId: chapter.key
            )
            DispatchQueue.main.async {
                if pages.isEmpty {
                    completion(.failure(LegacyKomgaError.invalidResponse))
                } else {
                    completion(.success(pages))
                }
            }
        }.resume()
    }

    private func opdsArchiveURL(kind: LegacyLocalChapterKind) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AidokuLegacyOPDS", isDirectory: true)
            .appendingPathComponent(aidokuLegacySanitizedPathComponent(server.id), isDirectory: true)
        return directory.appendingPathComponent(
            "\(aidokuLegacySanitizedPathComponent(book.id)).\(kind.rawValue)"
        )
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
