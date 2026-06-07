//
//  AidokuRunnerLegacyWasmRunner.swift
//  AidokuLegacy
//
//  iOS 12 AidokuRunner/Wasm3 bridge for modern .aix sources.
//

import Foundation
import Wasm3Legacy

struct AidokuRunnerLegacyWasmBackendFactory: AidokuRunnerLegacyBackendFactory {
    func makeRunner(sourceURL: URL, info: AidokuRunnerLegacySourceInfo) throws -> AidokuRunnerLegacyRunner {
        return try AidokuRunnerLegacyWasmRunner(sourceURL: sourceURL, info: info)
    }
}

final class AidokuRunnerLegacyWasmRunner: AidokuRunnerLegacyRunner {
    private let sourceKey: String
    private let store = GlobalStore()
    private let module: Module
    private let queue = DispatchQueue(label: "app.aidoku.legacy.wasm-runner")

    let features: AidokuRunnerLegacySourceFeatures

    init(sourceURL: URL, info: AidokuRunnerLegacySourceInfo) throws {
        sourceKey = info.info.id
        let bytes = try Data(contentsOf: sourceURL.appendingPathComponent("main.wasm"))
        let env = try Environment()
        let runtime = try env.createRuntime(stackSize: 1024 * 512)
        module = try runtime.parseAndLoadModule(bytes: [UInt8](bytes))

        try Env(module: module, printHandler: { print("[AidokuLegacy WASM] \($0)") }).link()
        try Std(module: module, store: store).link()
        try Defaults(module: module, store: store, defaultNamespace: info.info.id).link()
        try Net(module: module, store: store).link()
        try Html(module: module, store: store).link()

        features = AidokuRunnerLegacySourceFeatures(
            providesListings: (try? module.findFunction(name: "get_manga_list")) != nil,
            providesHome: (try? module.findFunction(name: "get_home")) != nil,
            dynamicFilters: (try? module.findFunction(name: "get_filters")) != nil,
            dynamicSettings: (try? module.findFunction(name: "get_settings")) != nil,
            dynamicListings: (try? module.findFunction(name: "get_listings")) != nil,
            providesImageRequests: (try? module.findFunction(name: "get_image_request")) != nil
        )

        if let start = try? module.findFunction(name: "start") {
            try start.call()
        }
    }

    func getSearchMangaList(
        query: String?,
        page: Int,
        filters: [AidokuRunnerLegacyFilterValue],
        completion: @escaping (Result<AidokuRunnerLegacyMangaPageResult, Error>) -> Void
    ) {
        run(completion: completion) {
            let function = try self.module.findFunction(name: "get_search_manga_list")
            let queryPointer = self.store.store(query ?? "")
            defer { self.store.remove(at: queryPointer) }
            let encodedFilters = filters.map { FilterValue.text(id: $0.id, value: $0.value) }
            let filterPointer = try self.store.storeEncoded(encodedFilters)
            defer { self.store.remove(at: filterPointer) }

            let result: Int32 = try function.call(queryPointer, Int32(page), filterPointer)
            let data = try self.handleResult(result: result)
            var pageResult = try PostcardDecoder().decode(MangaPageResult.self, from: data)
            pageResult.setSourceKey(self.sourceKey)
            return pageResult.legacy(sourceKey: self.sourceKey)
        }
    }

    func getMangaList(
        listing: AidokuRunnerLegacyListing,
        page: Int,
        completion: @escaping (Result<AidokuRunnerLegacyMangaPageResult, Error>) -> Void
    ) {
        run(completion: completion) {
            let function = try self.module.findFunction(name: "get_manga_list")
            let listing = Listing(id: listing.id, name: listing.name, kind: ListingKind(rawValue: listing.kind.rawValue) ?? .default)
            let listingPointer = try self.store.storeEncoded(listing)
            defer { self.store.remove(at: listingPointer) }

            let result: Int32 = try function.call(listingPointer, Int32(page))
            let data = try self.handleResult(result: result)
            var pageResult = try PostcardDecoder().decode(MangaPageResult.self, from: data)
            pageResult.setSourceKey(self.sourceKey)
            return pageResult.legacy(sourceKey: self.sourceKey)
        }
    }

    func getMangaUpdate(
        manga: AidokuRunnerLegacyManga,
        needsDetails: Bool,
        needsChapters: Bool,
        completion: @escaping (Result<AidokuRunnerLegacyManga, Error>) -> Void
    ) {
        run(completion: completion) {
            let function = try self.module.findFunction(name: "get_manga_update")
            let mangaPointer = try self.store.storeEncoded(Manga(legacy: manga, sourceKey: self.sourceKey))
            defer { self.store.remove(at: mangaPointer) }

            let result: Int32 = try function.call(mangaPointer, needsDetails ? Int32(1) : Int32(0), needsChapters ? Int32(1) : Int32(0))
            let data = try self.handleResult(result: result)
            let updated = try PostcardDecoder().decode(Manga.self, from: data)
            return updated.copy(from: Manga(legacy: manga, sourceKey: self.sourceKey)).legacy(sourceKey: self.sourceKey)
        }
    }

    func getPageList(
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        completion: @escaping (Result<[AidokuRunnerLegacyPage], Error>) -> Void
    ) {
        run(completion: completion) {
            let function = try self.module.findFunction(name: "get_page_list")
            var manga = Manga(legacy: manga, sourceKey: self.sourceKey)
            manga.chapters = nil
            let mangaPointer = try self.store.storeEncoded(manga)
            defer { self.store.remove(at: mangaPointer) }
            let chapterPointer = try self.store.storeEncoded(Chapter(legacy: chapter))
            defer { self.store.remove(at: chapterPointer) }

            let result: Int32 = try function.call(mangaPointer, chapterPointer)
            let data = try self.handleResult(result: result)
            return try PostcardDecoder()
                .decode([PageCodable].self, from: data)
                .compactMap { $0.into()?.legacy }
        }
    }

    func getImageRequest(
        url: URL,
        completion: @escaping (Result<AidokuRunnerLegacyImageRequest, Error>) -> Void
    ) {
        run(completion: completion) {
            guard self.features.providesImageRequests else {
                return AidokuRunnerLegacyImageRequest(url: url, method: "GET", headers: [:], body: nil)
            }
            let function = try self.module.findFunction(name: "get_image_request")
            let urlPointer = try self.store.storeEncoded(url.absoluteString)
            defer { self.store.remove(at: urlPointer) }
            let result: Int32 = try function.call(urlPointer, Int32(-1))
            let data = try self.handleResult(result: result)
            let requestPointer = try PostcardDecoder().decode(Int32.self, from: data)
            defer { self.store.remove(at: requestPointer) }
            guard
                let request = self.store.fetch(from: requestPointer) as? NetRequest,
                let urlRequest = request.toUrlRequest(),
                let requestURL = urlRequest.url
            else {
                throw SourceError.missingResult
            }
            return AidokuRunnerLegacyImageRequest(
                url: requestURL,
                method: urlRequest.httpMethod ?? "GET",
                headers: urlRequest.allHTTPHeaderFields ?? [:],
                body: urlRequest.httpBody
            )
        }
    }

    private func run<T>(
        completion: @escaping (Result<T, Error>) -> Void,
        operation: @escaping () throws -> T
    ) {
        queue.async {
            let result: Result<T, Error>
            do {
                result = .success(try operation())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func handleResult(result: Int32) throws -> Data {
        if result < 0 {
            switch result {
                case -2: throw SourceError.unimplemented
                case -3: throw SourceError.networkError
                default: throw SourceError.missingResult
            }
        }

        let pointer = UInt32(result)
        let memory = try module.runtime.memory()
        let length: UInt32 = try memory.readValues(offset: pointer, length: 1)[0]

        if length == UInt32.max {
            let stringLength: UInt32 = try memory.readValues(offset: pointer + 8, length: 1)[0] - 12
            let message = try memory.readString(offset: pointer + 12, length: stringLength)
            try freeResult(pointer: result)
            throw SourceError.message(message)
        }

        let data = try memory.readData(offset: pointer + 8, length: length - 8)
        try freeResult(pointer: result)
        return data
    }

    private func freeResult(pointer: Int32) throws {
        let function = try module.findFunction(name: "free_result")
        try function.call(pointer)
    }
}

private extension Manga {
    init(legacy: AidokuRunnerLegacyManga, sourceKey: String) {
        self.init(
            sourceKey: sourceKey,
            key: legacy.key,
            title: legacy.title,
            cover: legacy.cover,
            artists: legacy.artists,
            authors: legacy.authors,
            description: legacy.description,
            url: legacy.url,
            tags: legacy.tags,
            chapters: legacy.chapters?.map { Chapter(legacy: $0) }
        )
    }

    func legacy(sourceKey: String) -> AidokuRunnerLegacyManga {
        return AidokuRunnerLegacyManga(
            sourceKey: sourceKey,
            key: key,
            title: title,
            cover: cover,
            artists: artists,
            authors: authors,
            description: description,
            url: url,
            tags: tags,
            chapters: chapters?.map { $0.legacy }
        )
    }
}

private extension Chapter {
    init(legacy: AidokuRunnerLegacyChapter) {
        self.init(
            key: legacy.key,
            title: legacy.title,
            chapterNumber: legacy.chapterNumber,
            volumeNumber: legacy.volumeNumber,
            dateUploaded: legacy.dateUploaded,
            scanlators: legacy.scanlators,
            url: legacy.url,
            language: legacy.language,
            thumbnail: legacy.thumbnail,
            locked: false
        )
    }

    var legacy: AidokuRunnerLegacyChapter {
        return AidokuRunnerLegacyChapter(
            key: key,
            title: title,
            chapterNumber: chapterNumber,
            volumeNumber: volumeNumber,
            dateUploaded: dateUploaded,
            scanlators: scanlators,
            url: url,
            language: language,
            thumbnail: thumbnail
        )
    }
}

private extension MangaPageResult {
    func legacy(sourceKey: String) -> AidokuRunnerLegacyMangaPageResult {
        return AidokuRunnerLegacyMangaPageResult(
            entries: entries.map { $0.legacy(sourceKey: sourceKey) },
            hasNextPage: hasNextPage
        )
    }
}

private extension Page {
    var legacy: AidokuRunnerLegacyPage? {
        switch content {
            case .url(let url, _):
                return AidokuRunnerLegacyPage(content: .url(url), hasDescription: hasDescription, description: description)
            case .text(let string):
                return AidokuRunnerLegacyPage(content: .text(string), hasDescription: hasDescription, description: description)
            case .zipFile(let url, let filePath):
                return AidokuRunnerLegacyPage(content: .zipFile(url: url, filePath: filePath), hasDescription: hasDescription, description: description)
            case .image:
                return nil
        }
    }
}
