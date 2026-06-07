//
//  AidokuRunnerLegacyModels.swift
//  AidokuLegacy
//
//  Personal-use iOS 12 source runner API surface.
//

import Foundation
import UIKit

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

enum AidokuRunnerLegacyJSONValueType {
    case null
    case bool
    case int
    case double
    case string
    case stringArray
    case intArray
    case object
}

struct AidokuRunnerLegacyJSONValue: Codable {
    let type: AidokuRunnerLegacyJSONValueType

    var boolValue: Bool?
    var intValue: Int?
    var doubleValue: Double?
    var stringValue: String?
    var stringArrayValue: [String]?
    var intArrayValue: [Int]?
    var objectValue: [String: AidokuRunnerLegacyJSONValue]?

    var userDefaultsValue: Any? {
        switch type {
            case .null:
                return nil
            case .bool:
                return boolValue
            case .int:
                return intValue
            case .double:
                return doubleValue
            case .string:
                return stringValue
            case .stringArray:
                return stringArrayValue
            case .intArray:
                return intArrayValue
            case .object:
                var result: [String: Any] = [:]
                for (key, value) in objectValue ?? [:] {
                    if let rawValue = value.userDefaultsValue {
                        result[key] = rawValue
                    }
                }
                return result
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            type = .bool
            boolValue = value
        } else if let value = try? container.decode(Int.self) {
            type = .int
            intValue = value
            doubleValue = Double(value)
        } else if let value = try? container.decode(Double.self) {
            type = .double
            intValue = Int(value)
            doubleValue = value
        } else if let value = try? container.decode(String.self) {
            type = .string
            stringValue = value
        } else if let value = try? container.decode([Int].self) {
            type = .intArray
            intArrayValue = value
        } else if let value = try? container.decode([String].self) {
            type = .stringArray
            stringArrayValue = value
        } else if let value = try? container.decode([String: AidokuRunnerLegacyJSONValue].self) {
            type = .object
            objectValue = value
        } else {
            type = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch type {
            case .null:
                try container.encodeNil()
            case .bool:
                try container.encode(boolValue)
            case .int:
                try container.encode(intValue)
            case .double:
                try container.encode(doubleValue)
            case .string:
                try container.encode(stringValue)
            case .stringArray:
                try container.encode(stringArrayValue)
            case .intArray:
                try container.encode(intArrayValue)
            case .object:
                try container.encode(objectValue)
        }
    }
}

struct AidokuRunnerLegacySettingItem: Codable {
    var type: String
    var key: String?
    var urlKey: String?
    var title: String?
    var subtitle: String?
    var footer: String?
    var defaultValue: AidokuRunnerLegacyJSONValue?
    var values: [String]?
    var titles: [String]?
    var items: [AidokuRunnerLegacySettingItem]?

    enum CodingKeys: String, CodingKey {
        case type
        case key
        case urlKey
        case title
        case subtitle
        case footer
        case defaultValue = "default"
        case values
        case titles
        case items
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

struct AidokuRunnerLegacyMangaWithChapter: Hashable {
    var manga: AidokuRunnerLegacyManga
    var chapter: AidokuRunnerLegacyChapter
}

struct AidokuRunnerLegacyHome: Hashable {
    var components: [AidokuRunnerLegacyHomeComponent]
}

struct AidokuRunnerLegacyHomeComponent: Hashable {
    var title: String?
    var subtitle: String?
    var value: Value

    enum Value: Hashable {
        case imageScroller(
            links: [AidokuRunnerLegacyHomeLink],
            autoScrollInterval: TimeInterval?,
            width: Int?,
            height: Int?
        )
        case bigScroller(entries: [AidokuRunnerLegacyManga], autoScrollInterval: TimeInterval?)
        case scroller(entries: [AidokuRunnerLegacyHomeLink], listing: AidokuRunnerLegacyListing?)
        case mangaList(
            ranking: Bool,
            pageSize: Int?,
            entries: [AidokuRunnerLegacyHomeLink],
            listing: AidokuRunnerLegacyListing?
        )
        case mangaChapterList(
            pageSize: Int?,
            entries: [AidokuRunnerLegacyMangaWithChapter],
            listing: AidokuRunnerLegacyListing?
        )
        case filters([AidokuRunnerLegacyHomeFilterItem])
        case links([AidokuRunnerLegacyHomeLink])
    }
}

struct AidokuRunnerLegacyHomeFilterItem: Hashable {
    var title: String
    var values: [AidokuRunnerLegacyFilterValue]?
}

struct AidokuRunnerLegacyHomeLink: Hashable {
    var title: String
    var subtitle: String?
    var imageUrl: String?
    var value: Value?

    enum Value: Hashable {
        case url(String)
        case listing(AidokuRunnerLegacyListing)
        case manga(AidokuRunnerLegacyManga)
    }
}

struct AidokuRunnerLegacySortDefault: Codable, Hashable {
    let index: Int
    let ascending: Bool
}

struct AidokuRunnerLegacySelectFilter: Codable, Hashable {
    var isGenre: Bool
    var usesTagStyle: Bool
    var options: [String]
    var ids: [String]?
    var defaultValue: String?

    enum CodingKeys: String, CodingKey {
        case isGenre
        case usesTagStyle
        case options
        case ids
        case defaultValue = "default"
    }

    init(
        isGenre: Bool = false,
        usesTagStyle: Bool? = nil,
        options: [String],
        ids: [String]? = nil,
        defaultValue: String? = nil
    ) {
        self.isGenre = isGenre
        self.usesTagStyle = usesTagStyle ?? isGenre
        self.options = options
        self.ids = ids
        self.defaultValue = defaultValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isGenre = try container.decodeIfPresent(Bool.self, forKey: .isGenre) ?? false
        usesTagStyle = try container.decodeIfPresent(Bool.self, forKey: .usesTagStyle) ?? isGenre
        options = try container.decode([String].self, forKey: .options)
        ids = try container.decodeIfPresent([String].self, forKey: .ids)
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
    }
}

struct AidokuRunnerLegacyMultiSelectFilter: Codable, Hashable {
    var isGenre: Bool
    var canExclude: Bool
    var usesTagStyle: Bool
    var options: [String]
    var ids: [String]?
    var defaultIncluded: [String]?
    var defaultExcluded: [String]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isGenre = try container.decodeIfPresent(Bool.self, forKey: .isGenre) ?? false
        canExclude = try container.decodeIfPresent(Bool.self, forKey: .canExclude) ?? false
        usesTagStyle = try container.decodeIfPresent(Bool.self, forKey: .usesTagStyle) ?? isGenre
        options = try container.decode([String].self, forKey: .options)
        ids = try container.decodeIfPresent([String].self, forKey: .ids)
        defaultIncluded = try container.decodeIfPresent([String].self, forKey: .defaultIncluded)
        defaultExcluded = try container.decodeIfPresent([String].self, forKey: .defaultExcluded)
    }
}

struct AidokuRunnerLegacyFilter: Codable, Hashable {
    enum Value: Hashable {
        case text(placeholder: String?)
        case sort(canAscend: Bool, options: [String], defaultValue: AidokuRunnerLegacySortDefault?)
        case check(name: String?, canExclude: Bool, defaultValue: Bool?)
        case select(AidokuRunnerLegacySelectFilter)
        case multiselect(AidokuRunnerLegacyMultiSelectFilter)
        case note(String)
        case range(min: Float?, max: Float?, decimal: Bool)
    }

    var id: String
    var title: String?
    var hideFromHeader: Bool?
    var value: Value

    init(id: String, title: String? = nil, hideFromHeader: Bool? = nil, value: Value) {
        self.id = id
        self.title = title
        self.hideFromHeader = hideFromHeader
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        hideFromHeader = try container.decodeIfPresent(Bool.self, forKey: .hideFromHeader)
        let type = try container.decode(String.self, forKey: .type)
        self.id = id ?? title ?? type

        switch type {
            case "text":
                value = .text(placeholder: try container.decodeIfPresent(String.self, forKey: .placeholder))
            case "sort":
                value = .sort(
                    canAscend: try container.decodeIfPresent(Bool.self, forKey: .canAscend) ?? true,
                    options: try container.decode([String].self, forKey: .options),
                    defaultValue: try container.decodeIfPresent(AidokuRunnerLegacySortDefault.self, forKey: .defaultValue)
                )
            case "check":
                value = .check(
                    name: try container.decodeIfPresent(String.self, forKey: .name),
                    canExclude: try container.decodeIfPresent(Bool.self, forKey: .canExclude) ?? false,
                    defaultValue: try container.decodeIfPresent(Bool.self, forKey: .defaultValue)
                )
            case "select":
                value = .select(try AidokuRunnerLegacySelectFilter(from: decoder))
            case "multi-select":
                value = .multiselect(try AidokuRunnerLegacyMultiSelectFilter(from: decoder))
            case "note":
                value = .note(try container.decode(String.self, forKey: .text))
            case "range":
                value = .range(
                    min: try container.decodeIfPresent(Float.self, forKey: .min),
                    max: try container.decodeIfPresent(Float.self, forKey: .max),
                    decimal: try container.decodeIfPresent(Bool.self, forKey: .decimal) ?? false
                )
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Invalid filter type."
                )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(hideFromHeader, forKey: .hideFromHeader)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case title
        case hideFromHeader
        case placeholder
        case canAscend
        case options
        case defaultValue = "default"
        case canExclude
        case text
        case name
        case min
        case max
        case decimal
    }
}

enum AidokuRunnerLegacyFilterValue: Hashable, Codable {
    case text(id: String, value: String)
    case sort(id: String, index: Int, ascending: Bool)
    case check(id: String, value: Int)
    case select(id: String, value: String)
    case multiselect(id: String, included: [String], excluded: [String])
    case range(id: String, from: Float?, to: Float?)

    var id: String {
        switch self {
            case .text(let id, _),
                 .sort(let id, _, _),
                 .check(let id, _),
                 .select(let id, _),
                 .multiselect(let id, _, _),
                 .range(let id, _, _):
                return id
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(UInt8.self, forKey: .type)
        let id = try container.decode(String.self, forKey: .id)
        switch type {
            case 0:
                self = .text(id: id, value: try container.decode(String.self, forKey: .value))
            case 1:
                self = .sort(
                    id: id,
                    index: Int(try container.decode(Int32.self, forKey: .index)),
                    ascending: try container.decode(Bool.self, forKey: .ascending)
                )
            case 2:
                self = .check(id: id, value: try container.decode(Int.self, forKey: .value))
            case 3:
                self = .select(id: id, value: try container.decode(String.self, forKey: .value))
            case 4:
                self = .multiselect(
                    id: id,
                    included: try container.decode([String].self, forKey: .included),
                    excluded: try container.decode([String].self, forKey: .excluded)
                )
            case 5:
                self = .range(
                    id: id,
                    from: try container.decodeIfPresent(Float.self, forKey: .from),
                    to: try container.decodeIfPresent(Float.self, forKey: .to)
                )
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Invalid filter value type."
                )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
            case .text(let id, let value):
                try container.encode(UInt8(0), forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(value, forKey: .value)
            case .sort(let id, let index, let ascending):
                try container.encode(UInt8(1), forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(Int32(index), forKey: .index)
                try container.encode(ascending, forKey: .ascending)
            case .check(let id, let value):
                try container.encode(UInt8(2), forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(value, forKey: .value)
            case .select(let id, let value):
                try container.encode(UInt8(3), forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(value, forKey: .value)
            case .multiselect(let id, let included, let excluded):
                try container.encode(UInt8(4), forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(included, forKey: .included)
                try container.encode(excluded, forKey: .excluded)
            case .range(let id, let from, let to):
                try container.encode(UInt8(5), forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encodeIfPresent(from, forKey: .from)
                try container.encodeIfPresent(to, forKey: .to)
        }
    }

    enum CodingKeys: CodingKey {
        case id
        case type
        case index
        case value
        case ascending
        case included
        case excluded
        case from
        case to
    }
}

struct AidokuRunnerLegacySourceFeatures {
    var providesListings: Bool
    var providesHome: Bool
    var dynamicFilters: Bool
    var dynamicSettings: Bool
    var dynamicListings: Bool
    var processesPages: Bool
    var providesImageRequests: Bool
}

struct AidokuRunnerLegacyImageRequest {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data?
}

struct AidokuRunnerLegacyRequest: Codable {
    @URLAsString var url: URL?
    let headers: [String: String]
}

struct AidokuRunnerLegacyResponse: Codable {
    let code: UInt16
    let headers: [String: String]
    let request: AidokuRunnerLegacyRequest
    let image: ImageRef

    init(code: Int, headers: [String: String], request: AidokuRunnerLegacyRequest, image: ImageRef) {
        self.code = UInt16(code)
        self.headers = headers
        self.request = request
        self.image = image
    }
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

    func getHome(
        completion: @escaping (Result<AidokuRunnerLegacyHome, Error>) -> Void
    )

    func getFilters(
        completion: @escaping (Result<[AidokuRunnerLegacyFilter], Error>) -> Void
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

    func processPageImage(
        data: Data,
        response: HTTPURLResponse,
        request: URLRequest,
        context: [String: String]?,
        completion: @escaping (Result<UIImage?, Error>) -> Void
    )
}

final class AidokuRunnerLegacyUnavailableRunner: AidokuRunnerLegacyRunner {
    let features = AidokuRunnerLegacySourceFeatures(
        providesListings: false,
        providesHome: false,
        dynamicFilters: false,
        dynamicSettings: false,
        dynamicListings: false,
        processesPages: false,
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

    func getHome(
        completion: @escaping (Result<AidokuRunnerLegacyHome, Error>) -> Void
    ) {
        completion(.failure(AidokuRunnerLegacyError.backendUnavailable))
    }

    func getFilters(
        completion: @escaping (Result<[AidokuRunnerLegacyFilter], Error>) -> Void
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

    func processPageImage(
        data: Data,
        response: HTTPURLResponse,
        request: URLRequest,
        context: [String: String]?,
        completion: @escaping (Result<UIImage?, Error>) -> Void
    ) {
        completion(.failure(AidokuRunnerLegacyError.backendUnavailable))
    }
}
