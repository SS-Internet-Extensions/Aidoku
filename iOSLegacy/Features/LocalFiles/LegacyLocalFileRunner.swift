//
//  LegacyLocalFileRunner.swift
//  AidokuLegacy
//
//  An AidokuRunnerLegacyRunner that serves pages for a single imported local
//  chapter, so local files can be opened with the existing reader without a
//  WASM source. Every capability except page listing is disabled.
//

import Foundation
import UIKit

final class LegacyLocalFileRunner: AidokuRunnerLegacyRunner {
    private let localManga: LegacyLocalManga
    private let localChapter: LegacyLocalChapter
    private let queue = DispatchQueue(label: "AidokuLegacy.localFileRunner", qos: .userInitiated)

    let features = AidokuRunnerLegacySourceFeatures(
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

    init(localManga: LegacyLocalManga, localChapter: LegacyLocalChapter) {
        self.localManga = localManga
        self.localChapter = localChapter
    }

    func getPageList(
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        completion: @escaping (Result<[AidokuRunnerLegacyPage], Error>) -> Void
    ) {
        queue.async {
            let pages = LegacyLocalFilePageProvider.pages(for: self.localChapter, mangaId: self.localManga.id)
            DispatchQueue.main.async {
                completion(.success(pages))
            }
        }
    }

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

    func getImageRequest(
        url: URL,
        context: [String: String]?,
        completion: @escaping (Result<AidokuRunnerLegacyImageRequest, Error>) -> Void
    ) {
        completion(.failure(AidokuRunnerLegacyError.backendUnavailable))
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
