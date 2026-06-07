//
//  AidokuRunnerLegacyModels.swift
//  AidokuLegacy
//
//  Personal-use iOS 12 source runner API surface.
//

import Foundation

enum AidokuRunnerLegacyError: LocalizedError {
    case invalidPackage
    case missingSourceInfo
    case missingExecutable
    case backendUnavailable

    var errorDescription: String? {
        switch self {
            case .invalidPackage:
                return "The source package is invalid."
            case .missingSourceInfo:
                return "The source package is missing source.json."
            case .missingExecutable:
                return "The source package is missing main.wasm."
            case .backendUnavailable:
                return "AidokuRunnerLegacy has not been connected to a WASM backend yet."
        }
    }
}

enum AidokuRunnerLegacySourceContentRating: Int, Codable {
    case safe = 0
    case containsNsfw = 1
    case primarilyNsfw = 2
}

enum AidokuRunnerLegacyListingKind: UInt8, Codable {
    case `default` = 0
    case list = 1
}

enum AidokuRunnerLegacyLanguageSelectType: String, Codable {
    case single
    case multiple
}

struct AidokuRunnerLegacyListing: Codable, Hashable {
    var id: String
    var name: String
    var kind: AidokuRunnerLegacyListingKind

    init(id: String, name: String, kind: AidokuRunnerLegacyListingKind = .default) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let singleValueContainer = try decoder.singleValueContainer()
        if let name = try? singleValueContainer.decode(String.self) {
            self.id = name
            self.name = name
            self.kind = .default
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? id
        if let decodedKind = try? container.decode(AidokuRunnerLegacyListingKind.self, forKey: .kind) {
            kind = decodedKind
        } else if let kindString = try? container.decode(String.self, forKey: .kind), kindString == "list" {
            kind = .list
        } else {
            kind = .default
        }
    }
}

struct AidokuRunnerLegacySourceInfo: Codable {
    let info: Info
    let listings: [AidokuRunnerLegacyListing]?
    let config: Configuration?

    struct Info: Codable {
        let id: String
        let name: String
        let altNames: [String]?
        let version: Int
        let url: String?
        let urls: [String]?
        let contentRating: AidokuRunnerLegacySourceContentRating?
        let languages: [String]
        let minAppVersion: String?
        let maxAppVersion: String?
    }

    struct Configuration: Codable {
        let languageSelectType: AidokuRunnerLegacyLanguageSelectType?
        let supportsArtistSearch: Bool?
        let supportsAuthorSearch: Bool?
        let supportsTagSearch: Bool?
        let allowsBaseUrlSelect: Bool?
        let breakingChangeVersion: Int?
        let hidesFiltersWhileSearching: Bool?
        let maximumParallelRequests: Int?
    }
}

struct AidokuRunnerLegacyManga: Hashable, Codable {
    var sourceKey: String
    let key: String
    var title: String
    var cover: String?
    var artists: [String]?
    var authors: [String]?
    var description: String?
    var url: URL?
    var tags: [String]?
    var chapters: [AidokuRunnerLegacyChapter]?
}

struct AidokuRunnerLegacyChapter: Hashable, Codable {
    let key: String
    var title: String?
    var chapterNumber: Float?
    var volumeNumber: Float?
    var dateUploaded: Date?
    var scanlators: [String]?
    var url: URL?
    var language: String?
    var thumbnail: String?
}

struct AidokuRunnerLegacyPage: Hashable {
    enum Content: Hashable {
        case url(URL, context: [String: String]?)
        case image(Data)
        case text(String)
        case zipFile(url: URL, filePath: String)
    }

    var content: Content
    var hasDescription: Bool
    var description: String?
}

struct AidokuRunnerLegacyMangaPageResult {
    var entries: [AidokuRunnerLegacyManga]
    var hasNextPage: Bool
}

struct AidokuRunnerLegacyFilterValue {
    var id: String
    var value: String
}

struct AidokuRunnerLegacySourceFeatures {
    var providesListings: Bool
    var providesHome: Bool
    var dynamicFilters: Bool
    var dynamicSettings: Bool
    var dynamicListings: Bool
    var providesImageRequests: Bool
}

struct AidokuRunnerLegacyImageRequest {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data?
}

protocol AidokuRunnerLegacyRunner {
    var features: AidokuRunnerLegacySourceFeatures { get }

    func getSearchMangaList(
        query: String?,
        page: Int,
        filters: [AidokuRunnerLegacyFilterValue],
        completion: @escaping (Result<AidokuRunnerLegacyMangaPageResult, Error>) -> Void
    )

    func getMangaList(
        listing: AidokuRunnerLegacyListing,
        page: Int,
        completion: @escaping (Result<AidokuRunnerLegacyMangaPageResult, Error>) -> Void
    )

    func getListings(
        completion: @escaping (Result<[AidokuRunnerLegacyListing], Error>) -> Void
    )

    func getMangaUpdate(
        manga: AidokuRunnerLegacyManga,
        needsDetails: Bool,
        needsChapters: Bool,
        completion: @escaping (Result<AidokuRunnerLegacyManga, Error>) -> Void
    )

    func getPageList(
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        completion: @escaping (Result<[AidokuRunnerLegacyPage], Error>) -> Void
    )

    func getImageRequest(
        url: URL,
        context: [String: String]?,
        completion: @escaping (Result<AidokuRunnerLegacyImageRequest, Error>) -> Void
    )
}

final class AidokuRunnerLegacyUnavailableRunner: AidokuRunnerLegacyRunner {
    let features = AidokuRunnerLegacySourceFeatures(
        providesListings: false,
        providesHome: false,
        dynamicFilters: false,
        dynamicSettings: false,
        dynamicListings: false,
        providesImageRequests: false
    )

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

    func getListings(
        completion: @escaping (Result<[AidokuRunnerLegacyListing], Error>) -> Void
    ) {
        completion(.failure(AidokuRunnerLegacyError.backendUnavailable))
    }

    func getMangaUpdate(
        manga: AidokuRunnerLegacyManga,
        needsDetails: Bool,
        needsChapters: Bool,
        completion: @escaping (Result<AidokuRunnerLegacyManga, Error>) -> Void
    ) {
        completion(.failure(AidokuRunnerLegacyError.backendUnavailable))
    }

    func getPageList(
        manga: AidokuRunnerLegacyManga,
        chapter: AidokuRunnerLegacyChapter,
        completion: @escaping (Result<[AidokuRunnerLegacyPage], Error>) -> Void
    ) {
        completion(.failure(AidokuRunnerLegacyError.backendUnavailable))
    }

    func getImageRequest(
        url: URL,
        context: [String: String]?,
        completion: @escaping (Result<AidokuRunnerLegacyImageRequest, Error>) -> Void
    ) {
        completion(.failure(AidokuRunnerLegacyError.backendUnavailable))
    }
}
