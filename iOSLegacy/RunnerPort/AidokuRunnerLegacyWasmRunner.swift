//
//  AidokuRunnerLegacyWasmRunner.swift
//  AidokuLegacy
//
//  iOS 12 AidokuRunner/Wasm3 bridge for modern .aix sources.
//

import Foundation
import UIKit
import Wasm3Legacy

struct AidokuRunnerLegacyWasmBackendFactory: AidokuRunnerLegacyBackendFactory {
    func makeRunner(sourceURL: URL, info: AidokuRunnerLegacySourceInfo) throws -> AidokuRunnerLegacyRunner {
        return try AidokuRunnerLegacyWasmRunner(sourceURL: sourceURL, info: info)
    }
}

private struct PartialHomeResultValue {
    var currentHome: Home?
    var decodingError: Error?
}

final class AidokuRunnerLegacyWasmRunner: AidokuRunnerLegacyRunner {
    private let sourceKey: String
    private let store = GlobalStore()
    private let partialResultHandler = LegacyPartialResultHandler()
    private let module: Module
    private let queue = DispatchQueue(label: "app.aidoku.legacy.wasm-runner")

    let features: AidokuRunnerLegacySourceFeatures

    init(sourceURL: URL, info: AidokuRunnerLegacySourceInfo) throws {
        sourceKey = info.info.id
        let bytes = try Data(contentsOf: sourceURL.appendingPathComponent("main.wasm"))
        let env = try Environment()
        let runtime = try env.createRuntime(stackSize: 1024 * 512)
        module = try runtime.parseAndLoadModule(bytes: [UInt8](bytes))

        try Env(
            module: module,
            partialResultHandler: partialResultHandler,
            printHandler: { print("[AidokuLegacy WASM] \($0)") }
        ).link()
        try Std(
            module: module,
            store: store,
            printHandler: { print("[AidokuLegacy WASM] \($0)") }
        ).link()
        try Defaults(module: module, store: store, defaultNamespace: info.info.id).link()
        try Net(module: module, store: store).link()
        try Html(module: module, store: store).link()
        try JavaScript(module: module, store: store).link()
        try Canvas(module: module, store: store).link()

        features = AidokuRunnerLegacySourceFeatures(
            providesListings: (try? module.findFunction(name: "get_manga_list")) != nil,
            providesHome: (try? module.findFunction(name: "get_home")) != nil,
            dynamicFilters: (try? module.findFunction(name: "get_filters")) != nil,
            dynamicSettings: (try? module.findFunction(name: "get_settings")) != nil,
            dynamicListings: (try? module.findFunction(name: "get_listings")) != nil,
            processesPages: (try? module.findFunction(name: "process_page_image")) != nil,
            providesImageRequests: (try? module.findFunction(name: "get_image_request")) != nil,
            providesPageDescriptions: (try? module.findFunction(name: "get_page_description")) != nil,
            providesAlternateCovers: (try? module.findFunction(name: "get_alternate_covers")) != nil,
            providesBaseUrl: (try? module.findFunction(name: "get_base_url")) != nil,
            handlesNotifications: (try? module.findFunction(name: "handle_notification")) != nil,
            handlesDeepLinks: (try? module.findFunction(name: "handle_deep_link")) != nil,
            handlesBasicLogin: (try? module.findFunction(name: "handle_basic_login")) != nil,
            handlesWebLogin: (try? module.findFunction(name: "handle_web_login")) != nil,
            handlesMigration: (try? module.findFunction(name: "handle_key_migration")) != nil
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
            let filterPointer = try self.store.storeEncoded(filters)
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

    func getListings(
        completion: @escaping (Result<[AidokuRunnerLegacyListing], Error>) -> Void
    ) {
        run(completion: completion) {
            guard self.features.dynamicListings else {
                return []
            }
            let function = try self.module.findFunction(name: "get_listings")
            let result: Int32 = try function.call()
            let data = try self.handleResult(result: result)
            return try PostcardDecoder()
                .decode([Listing].self, from: data)
                .map {
                    AidokuRunnerLegacyListing(
                        id: $0.id,
                        name: $0.name,
                        kind: AidokuRunnerLegacyListingKind(rawValue: $0.kind.rawValue) ?? .default
                    )
                }
        }
    }

    func getHome(
        completion: @escaping (Result<AidokuRunnerLegacyHome, Error>) -> Void
    ) {
        run(completion: completion) {
            guard self.features.providesHome else {
                throw SourceError.unimplemented
            }
            let callbackID = self.partialResultHandler.register { partial, data in
                var partial = (partial as? PartialHomeResultValue) ?? PartialHomeResultValue()
                do {
                    let result = try PostcardDecoder().decode(HomePartialResult.self, from: data)
                    switch result {
                        case .layout(var home):
                            home.setSourceKey(self.sourceKey)
                            partial.currentHome = home
                        case .component(var component):
                            component.setSourceKey(self.sourceKey)
                            if let currentHome = partial.currentHome {
                                var components = currentHome.components
                                if let index = components.firstIndex(where: { $0.title == component.title }) {
                                    components[index] = component
                                } else {
                                    components.append(component)
                                }
                                partial.currentHome = Home(components: components)
                            } else {
                                partial.currentHome = Home(components: [component])
                            }
                    }
                } catch {
                    partial.decodingError = error
                }
                return partial
            }
            defer { self.partialResultHandler.remove(id: callbackID) }

            let function = try self.module.findFunction(name: "get_home")
            let result: Int32 = try function.call()
            let data = try self.handleResult(result: result)
            var home = try PostcardDecoder().decode(Home.self, from: data)
            home.setSourceKey(self.sourceKey)
            if let partial = self.partialResultHandler.data(for: callbackID) as? PartialHomeResultValue {
                if let error = partial.decodingError {
                    throw error
                }
                if home.components.isEmpty, let partialHome = partial.currentHome {
                    home = partialHome
                }
            }
            return home.legacy(sourceKey: self.sourceKey)
        }
    }

    func getFilters(
        completion: @escaping (Result<[AidokuRunnerLegacyFilter], Error>) -> Void
    ) {
        run(completion: completion) {
            guard self.features.dynamicFilters else {
                return []
            }
            let function = try self.module.findFunction(name: "get_filters")
            let result: Int32 = try function.call()
            let data = try self.handleResult(result: result)
            return try PostcardDecoder().decode([AidokuRunnerLegacyFilter].self, from: data)
        }
    }

    func getSettings(
        completion: @escaping (Result<[AidokuRunnerLegacySettingItem], Error>) -> Void
    ) {
        run(completion: completion) {
            guard self.features.dynamicSettings else {
                return []
            }
            let function = try self.module.findFunction(name: "get_settings")
            let result: Int32 = try function.call()
            let data = try self.handleResult(result: result)
            return try PostcardDecoder().decode([AidokuRunnerLegacySettingItem].self, from: data)
        }
    }

    func getMangaUpdate(
        manga: AidokuRunnerLegacyManga,
        needsDetails: Bool,
        needsChapters: Bool,
        completion: @escaping (Result<AidokuRunnerLegacyManga, Error>) -> Void
    ) {
        run(completion: completion) {
            let callbackID = self.partialResultHandler.register { current, data in
                guard let partial = try? PostcardDecoder().decode(Manga.self, from: data) else {
                    return current
                }
                if let current = current as? Manga {
                    return current.copy(from: partial)
                }
                return partial
            }
            defer { self.partialResultHandler.remove(id: callbackID) }

            let function = try self.module.findFunction(name: "get_manga_update")
            let mangaPointer = try self.store.storeEncoded(Manga(legacy: manga, sourceKey: self.sourceKey))
            defer { self.store.remove(at: mangaPointer) }

            let result: Int32 = try function.call(mangaPointer, needsDetails ? Int32(1) : Int32(0), needsChapters ? Int32(1) : Int32(0))
            let data = try self.handleResult(result: result)
            let original = Manga(legacy: manga, sourceKey: self.sourceKey)
            let updated = try PostcardDecoder().decode(Manga.self, from: data)
            var merged = original
            if let partial = self.partialResultHandler.data(for: callbackID) as? Manga {
                merged = merged.copy(from: partial)
            }
            merged = merged.copy(from: updated)
            return merged.legacy(sourceKey: self.sourceKey)
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
                .compactMap { $0.into()?.legacy(store: self.store) }
        }
    }

    func getImageRequest(
        url: URL,
        context: [String: String]?,
        completion: @escaping (Result<AidokuRunnerLegacyImageRequest, Error>) -> Void
    ) {
        run(completion: completion) {
            guard self.features.providesImageRequests else {
                return AidokuRunnerLegacyImageRequest(url: url, method: "GET", headers: [:], body: nil)
            }
            let function = try self.module.findFunction(name: "get_image_request")
            let urlPointer = try self.store.storeEncoded(url.absoluteString)
            defer { self.store.remove(at: urlPointer) }
            let contextPointer = try self.store.storeOptionalEncoded(context)
            defer {
                if contextPointer >= 0 {
                    self.store.remove(at: contextPointer)
                }
            }
            let result: Int32 = try function.call(urlPointer, contextPointer)
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

    func processPageImage(
        data: Data,
        response: HTTPURLResponse,
        request: URLRequest,
        context: [String: String]?,
        completion: @escaping (Result<UIImage?, Error>) -> Void
    ) {
        run(completion: completion) {
            guard self.features.processesPages else {
                return nil
            }
            let requestHeaders = request.allHTTPHeaderFields ?? [:]
            let responseHeaders = response.allHeaderFields.reduce(into: [String: String]()) { result, header in
                guard let key = header.key as? String else { return }
                result[key] = String(describing: header.value)
            }
            let imageRef = self.store.store(data)
            defer { self.store.remove(at: imageRef) }
            let response = AidokuRunnerLegacyResponse(
                code: response.statusCode,
                headers: responseHeaders,
                request: AidokuRunnerLegacyRequest(url: request.url, headers: requestHeaders),
                image: imageRef
            )
            let responsePointer = try self.store.storeEncoded(response)
            defer { self.store.remove(at: responsePointer) }
            let contextPointer = try self.store.storeOptionalEncoded(context)
            defer {
                if contextPointer >= 0 {
                    self.store.remove(at: contextPointer)
                }
            }

            let function = try self.module.findFunction(name: "process_page_image")
            let result: Int32 = try function.call(responsePointer, contextPointer)
            let resultData = try self.handleResult(result: result)
            let finalImageRef = try PostcardDecoder().decode(ImageRef.self, from: resultData)
            defer { self.store.remove(at: finalImageRef) }
            if let image = self.store.fetch(from: finalImageRef) as? UIImage {
                return image
            }
            if let data = self.store.fetch(from: finalImageRef) as? Data {
                return UIImage(data: data)
            }
            return nil
        }
    }

    func handleNotification(
        notification: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        run(completion: completion) {
            guard self.features.handlesNotifications else {
                return
            }
            let function = try self.module.findFunction(name: "handle_notification")
            let notificationPointer = try self.store.storeEncoded(notification)
            defer { self.store.remove(at: notificationPointer) }
            let _: Int32 = try function.call(notificationPointer)
        }
    }

    func handleBasicLogin(
        key: String,
        username: String,
        password: String,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        run(completion: completion) {
            guard self.features.handlesBasicLogin else {
                return true
            }
            let function = try self.module.findFunction(name: "handle_basic_login")
            let keyPointer = try self.store.storeEncoded(key)
            defer { self.store.remove(at: keyPointer) }
            let usernamePointer = try self.store.storeEncoded(username)
            defer { self.store.remove(at: usernamePointer) }
            let passwordPointer = try self.store.storeEncoded(password)
            defer { self.store.remove(at: passwordPointer) }

            let result: Int32 = try function.call(keyPointer, usernamePointer, passwordPointer)
            let data = try self.handleResult(result: result)
            return try PostcardDecoder().decode(Bool.self, from: data)
        }
    }

    func handleWebLogin(
        key: String,
        cookies: [String: String],
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        run(completion: completion) {
            guard self.features.handlesWebLogin else {
                return true
            }
            let function = try self.module.findFunction(name: "handle_web_login")
            let cookieKeys = Array(cookies.keys)
            let cookieValues = cookieKeys.map { cookies[$0] ?? "" }
            let keyPointer = try self.store.storeEncoded(key)
            defer { self.store.remove(at: keyPointer) }
            let cookieKeysPointer = try self.store.storeEncoded(cookieKeys)
            defer { self.store.remove(at: cookieKeysPointer) }
            let cookieValuesPointer = try self.store.storeEncoded(cookieValues)
            defer { self.store.remove(at: cookieValuesPointer) }

            let result: Int32 = try function.call(keyPointer, cookieKeysPointer, cookieValuesPointer)
            let data = try self.handleResult(result: result)
            return try PostcardDecoder().decode(Bool.self, from: data)
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

private extension Listing {
    var legacy: AidokuRunnerLegacyListing {
        return AidokuRunnerLegacyListing(
            id: id,
            name: name,
            kind: AidokuRunnerLegacyListingKind(rawValue: kind.rawValue) ?? .default
        )
    }
}

private extension Home {
    func legacy(sourceKey: String) -> AidokuRunnerLegacyHome {
        return AidokuRunnerLegacyHome(
            components: components.map { $0.legacy(sourceKey: sourceKey) }
        )
    }
}

private extension HomeComponent {
    func legacy(sourceKey: String) -> AidokuRunnerLegacyHomeComponent {
        return AidokuRunnerLegacyHomeComponent(
            title: title,
            subtitle: subtitle,
            value: value.legacy(sourceKey: sourceKey)
        )
    }
}

private extension HomeComponent.Value {
    func legacy(sourceKey: String) -> AidokuRunnerLegacyHomeComponent.Value {
        switch self {
            case .imageScroller(let links, let autoScrollInterval, let width, let height):
                return .imageScroller(
                    links: links.map { $0.legacy(sourceKey: sourceKey) },
                    autoScrollInterval: autoScrollInterval,
                    width: width,
                    height: height
                )
            case .bigScroller(let entries, let autoScrollInterval):
                return .bigScroller(
                    entries: entries.map { $0.legacy(sourceKey: sourceKey) },
                    autoScrollInterval: autoScrollInterval
                )
            case .scroller(let entries, let listing):
                return .scroller(
                    entries: entries.map { $0.legacy(sourceKey: sourceKey) },
                    listing: listing?.legacy
                )
            case .mangaList(let ranking, let pageSize, let entries, let listing):
                return .mangaList(
                    ranking: ranking,
                    pageSize: pageSize,
                    entries: entries.map { $0.legacy(sourceKey: sourceKey) },
                    listing: listing?.legacy
                )
            case .mangaChapterList(let pageSize, let entries, let listing):
                return .mangaChapterList(
                    pageSize: pageSize,
                    entries: entries.map { $0.legacy(sourceKey: sourceKey) },
                    listing: listing?.legacy
                )
            case .filters(let items):
                return .filters(items.map { $0.legacy })
            case .links(let links):
                return .links(links.map { $0.legacy(sourceKey: sourceKey) })
        }
    }
}

private extension HomeFilterItem {
    var legacy: AidokuRunnerLegacyHomeFilterItem {
        return AidokuRunnerLegacyHomeFilterItem(title: title, values: values)
    }
}

private extension HomeLink {
    func legacy(sourceKey: String) -> AidokuRunnerLegacyHomeLink {
        return AidokuRunnerLegacyHomeLink(
            title: title,
            subtitle: subtitle,
            imageUrl: imageUrl,
            value: value?.legacy(sourceKey: sourceKey)
        )
    }
}

private extension HomeLinkValue {
    func legacy(sourceKey: String) -> AidokuRunnerLegacyHomeLink.Value {
        switch self {
            case .url(let url):
                return .url(url)
            case .listing(let listing):
                return .listing(listing.legacy)
            case .manga(let manga):
                return .manga(manga.legacy(sourceKey: sourceKey))
        }
    }
}

private extension MangaWithChapter {
    func legacy(sourceKey: String) -> AidokuRunnerLegacyMangaWithChapter {
        return AidokuRunnerLegacyMangaWithChapter(
            manga: manga.legacy(sourceKey: sourceKey),
            chapter: chapter.legacy
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
            locked: legacy.locked
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
            thumbnail: thumbnail,
            locked: locked
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
    func legacy(store: GlobalStore) -> AidokuRunnerLegacyPage? {
        switch content {
            case .url(let url, let context):
                return AidokuRunnerLegacyPage(content: .url(url, context: context), hasDescription: hasDescription, description: description)
            case .text(let string):
                return AidokuRunnerLegacyPage(content: .text(string), hasDescription: hasDescription, description: description)
            case .zipFile(let url, let filePath):
                return AidokuRunnerLegacyPage(content: .zipFile(url: url, filePath: filePath), hasDescription: hasDescription, description: description)
            case .image(let imageRef):
                defer { store.remove(at: imageRef) }
                if let data = store.fetch(from: imageRef) as? Data {
                    return AidokuRunnerLegacyPage(content: .image(data), hasDescription: hasDescription, description: description)
                }
                if let image = store.fetch(from: imageRef) as? UIImage {
                    if let data = image.pngData() ?? image.jpegData(compressionQuality: 0.95) {
                        return AidokuRunnerLegacyPage(content: .image(data), hasDescription: hasDescription, description: description)
                    }
                }
                return nil
        }
    }
}
