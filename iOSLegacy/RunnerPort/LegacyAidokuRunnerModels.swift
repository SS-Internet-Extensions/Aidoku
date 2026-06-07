//
//  LegacyAidokuRunnerModels.swift
//  AidokuLegacy
//
//  Modern AidokuRunner postcard models used by .aix sources.
//

import Foundation

struct Manga: Hashable, Codable {
    @ExcludedFromCoding var sourceKey: String
    let key: String
    var title: String
    var cover: String?
    var artists: [String]?
    var authors: [String]?
    var description: String?
    @URLAsString var url: URL?
    var tags: [String]?
    var status: PublishingStatus
    var contentRating: ContentRating
    var viewer: Viewer
    var updateStrategy: UpdateStrategy
    var nextUpdateTime: Int?
    var chapters: [Chapter]?

    init(
        sourceKey: String,
        key: String,
        title: String,
        cover: String? = nil,
        artists: [String]? = nil,
        authors: [String]? = nil,
        description: String? = nil,
        url: URL? = nil,
        tags: [String]? = nil,
        status: PublishingStatus = .unknown,
        contentRating: ContentRating = .unknown,
        viewer: Viewer = .unknown,
        updateStrategy: UpdateStrategy = .always,
        nextUpdateTime: Int? = nil,
        chapters: [Chapter]? = nil
    ) {
        self.sourceKey = sourceKey
        self.key = key
        self.title = title
        self.cover = cover
        self.artists = artists
        self.authors = authors
        self.description = description
        self.url = url
        self.tags = tags
        self.status = status
        self.contentRating = contentRating
        self.viewer = viewer
        self.updateStrategy = updateStrategy
        self.nextUpdateTime = nextUpdateTime
        self.chapters = chapters
    }

    func copy(from manga: Manga) -> Manga {
        return Manga(
            sourceKey: manga.sourceKey.isEmpty ? sourceKey : manga.sourceKey,
            key: manga.key.isEmpty ? key : manga.key,
            title: manga.title.isEmpty ? title : manga.title,
            cover: manga.cover ?? cover,
            artists: manga.artists ?? artists,
            authors: manga.authors ?? authors,
            description: manga.description ?? description,
            url: manga.url ?? url,
            tags: manga.tags ?? tags,
            status: manga.status,
            contentRating: manga.contentRating,
            viewer: manga.viewer,
            updateStrategy: manga.updateStrategy,
            nextUpdateTime: manga.nextUpdateTime,
            chapters: manga.chapters ?? chapters
        )
    }
}

enum PublishingStatus: UInt8, Codable, CaseIterable {
    case unknown
    case ongoing
    case completed
    case cancelled
    case hiatus
}

enum ContentRating: UInt8, Codable, CaseIterable {
    case unknown
    case safe
    case suggestive
    case nsfw
}

enum Viewer: UInt8, Codable, CaseIterable {
    case unknown
    case leftToRight
    case rightToLeft
    case vertical
    case webtoon
}

enum UpdateStrategy: UInt8, Codable {
    case always
    case never
}

struct Chapter: Hashable, Codable {
    var key: String
    var title: String?
    var chapterNumber: Float?
    var volumeNumber: Float?
    @EpochDate var dateUploaded: Date?
    var scanlators: [String]?
    @URLAsString var url: URL?
    var language: String?
    var thumbnail: String?
    var locked: Bool
}

struct MangaPageResult: Codable {
    var entries: [Manga]
    var hasNextPage: Bool

    mutating func setSourceKey(_ sourceKey: String) {
        for index in entries.indices {
            entries[index].sourceKey = sourceKey
        }
    }
}

struct Listing: Hashable {
    var id: String
    var name: String
    var kind: ListingKind
}

enum ListingKind: UInt8, Codable {
    case `default`
    case list
}

extension Listing: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? id
        kind = (try? container.decode(ListingKind.self, forKey: .kind)) ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
    }

    enum CodingKeys: CodingKey {
        case id
        case name
        case kind
    }
}

enum FilterValue: Codable, Hashable {
    case text(id: String, value: String)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(UInt8.self, forKey: .type)
        let id = try container.decode(String.self, forKey: .id)
        let value = try container.decode(String.self, forKey: .value)
        self = .text(id: id, value: value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(UInt8(0), forKey: .type)
        switch self {
            case .text(let id, let value):
                try container.encode(id, forKey: .id)
                try container.encode(value, forKey: .value)
        }
    }

    enum CodingKeys: CodingKey {
        case id
        case type
        case value
    }
}

struct MangaWithChapter: Hashable, Codable {
    var manga: Manga
    var chapter: Chapter
}

struct Home: Hashable, Codable {
    var components: [HomeComponent]

    mutating func setSourceKey(_ sourceKey: String) {
        for index in components.indices {
            components[index].setSourceKey(sourceKey)
        }
    }
}

enum HomePartialResult {
    case layout(Home)
    case component(HomeComponent)
}

extension HomePartialResult: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(UInt8.self, forKey: .key)
        switch type {
            case 0:
                self = .layout(try container.decode(Home.self, forKey: .key))
            case 1:
                self = .component(try container.decode(HomeComponent.self, forKey: .key))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .key,
                    in: container,
                    debugDescription: "Invalid partial home type."
                )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
            case .layout(let home):
                try container.encode(UInt8(0), forKey: .key)
                try container.encode(home, forKey: .key)
            case .component(let component):
                try container.encode(UInt8(1), forKey: .key)
                try container.encode(component, forKey: .key)
        }
    }

    enum CodingKeys: CodingKey {
        case key
    }
}

struct HomeComponent: Hashable, Codable {
    var title: String?
    var subtitle: String?
    var value: Value

    enum Value: Hashable {
        case imageScroller(links: [HomeLink], autoScrollInterval: TimeInterval?, width: Int?, height: Int?)
        case bigScroller(entries: [Manga], autoScrollInterval: TimeInterval?)
        case scroller(entries: [HomeLink], listing: Listing?)
        case mangaList(ranking: Bool, pageSize: Int?, entries: [HomeLink], listing: Listing?)
        case mangaChapterList(pageSize: Int?, entries: [MangaWithChapter], listing: Listing?)
        case filters([HomeFilterItem])
        case links([HomeLink])

        var intValue: UInt8 {
            switch self {
                case .imageScroller:
                    return 0
                case .bigScroller:
                    return 1
                case .scroller:
                    return 2
                case .mangaList:
                    return 3
                case .mangaChapterList:
                    return 4
                case .filters:
                    return 5
                case .links:
                    return 6
            }
        }
    }
}

struct HomeFilterItem: Hashable, Codable {
    var title: String
    var values: [AidokuRunnerLegacyFilterValue]?
}

struct HomeLink: Hashable, Codable {
    var title: String
    var subtitle: String?
    var imageUrl: String?
    var value: HomeLinkValue?

    mutating func setSourceKey(_ sourceKey: String) {
        guard case .some(.manga(var manga)) = value else { return }
        manga.sourceKey = sourceKey
        value = .manga(manga)
    }
}

enum HomeLinkValue: Hashable {
    case url(String)
    case listing(Listing)
    case manga(Manga)
}

extension HomeLinkValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(UInt8.self, forKey: .key)
        switch type {
            case 0:
                self = .url(try container.decode(String.self, forKey: .key))
            case 1:
                self = .listing(try container.decode(Listing.self, forKey: .key))
            case 2:
                self = .manga(try container.decode(Manga.self, forKey: .key))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .key,
                    in: container,
                    debugDescription: "Invalid link type."
                )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
            case .url(let value):
                try container.encode(UInt8(0), forKey: .key)
                try container.encode(value, forKey: .key)
            case .listing(let value):
                try container.encode(UInt8(1), forKey: .key)
                try container.encode(value, forKey: .key)
            case .manga(let value):
                try container.encode(UInt8(2), forKey: .key)
                try container.encode(value, forKey: .key)
        }
    }

    enum CodingKeys: CodingKey {
        case key
    }
}

extension HomeComponent.Value: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(UInt8.self, forKey: .key)
        switch type {
            case 0:
                let links = try container.decode([HomeLink].self, forKey: .key)
                let autoScrollInterval = try container.decodeIfPresent(Float.self, forKey: .key).map(TimeInterval.init)
                let width = try container.decodeIfPresent(Int.self, forKey: .key)
                let height = try container.decodeIfPresent(Int.self, forKey: .key)
                self = .imageScroller(
                    links: links,
                    autoScrollInterval: autoScrollInterval,
                    width: width,
                    height: height
                )
            case 1:
                let entries = try container.decode([Manga].self, forKey: .key)
                let autoScrollInterval = try container.decodeIfPresent(Float.self, forKey: .key).map(TimeInterval.init)
                self = .bigScroller(entries: entries, autoScrollInterval: autoScrollInterval)
            case 2:
                let entries = try container.decode([HomeLink].self, forKey: .key)
                let listing = try container.decodeIfPresent(Listing.self, forKey: .key)
                self = .scroller(entries: entries, listing: listing)
            case 3:
                let ranking = try container.decode(Bool.self, forKey: .key)
                let pageSize = try container.decodeIfPresent(Int.self, forKey: .key)
                let entries = try container.decode([HomeLink].self, forKey: .key)
                let listing = try container.decodeIfPresent(Listing.self, forKey: .key)
                self = .mangaList(ranking: ranking, pageSize: pageSize, entries: entries, listing: listing)
            case 4:
                let pageSize = try container.decodeIfPresent(Int.self, forKey: .key)
                let entries = try container.decode([MangaWithChapter].self, forKey: .key)
                let listing = try container.decodeIfPresent(Listing.self, forKey: .key)
                self = .mangaChapterList(pageSize: pageSize, entries: entries, listing: listing)
            case 5:
                self = .filters(try container.decode([HomeFilterItem].self, forKey: .key))
            case 6:
                self = .links(try container.decode([HomeLink].self, forKey: .key))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .key,
                    in: container,
                    debugDescription: "Invalid home component type."
                )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(intValue, forKey: .key)
        switch self {
            case .imageScroller(let links, let autoScrollInterval, let width, let height):
                try container.encode(links, forKey: .key)
                try container.encodeIfPresent(autoScrollInterval.map { Float($0) }, forKey: .key)
                try container.encodeIfPresent(width, forKey: .key)
                try container.encodeIfPresent(height, forKey: .key)
            case .bigScroller(let entries, let autoScrollInterval):
                try container.encode(entries, forKey: .key)
                try container.encodeIfPresent(autoScrollInterval.map { Float($0) }, forKey: .key)
            case .scroller(let entries, let listing):
                try container.encode(entries, forKey: .key)
                try container.encodeIfPresent(listing, forKey: .key)
            case .mangaList(let ranking, let pageSize, let entries, let listing):
                try container.encode(ranking, forKey: .key)
                try container.encodeIfPresent(pageSize, forKey: .key)
                try container.encode(entries, forKey: .key)
                try container.encodeIfPresent(listing, forKey: .key)
            case .mangaChapterList(let pageSize, let entries, let listing):
                try container.encodeIfPresent(pageSize, forKey: .key)
                try container.encode(entries, forKey: .key)
                try container.encodeIfPresent(listing, forKey: .key)
            case .filters(let items):
                try container.encode(items, forKey: .key)
            case .links(let links):
                try container.encode(links, forKey: .key)
        }
    }

    enum CodingKeys: CodingKey {
        case key
    }
}

extension HomeComponent {
    mutating func setSourceKey(_ sourceKey: String) {
        switch value {
            case .imageScroller(var links, let autoScrollInterval, let width, let height):
                for index in links.indices {
                    links[index].setSourceKey(sourceKey)
                }
                value = .imageScroller(
                    links: links,
                    autoScrollInterval: autoScrollInterval,
                    width: width,
                    height: height
                )
            case .bigScroller(var entries, let autoScrollInterval):
                for index in entries.indices {
                    entries[index].sourceKey = sourceKey
                }
                value = .bigScroller(entries: entries, autoScrollInterval: autoScrollInterval)
            case .scroller(var entries, let listing):
                for index in entries.indices {
                    entries[index].setSourceKey(sourceKey)
                }
                value = .scroller(entries: entries, listing: listing)
            case .mangaList(let ranking, let pageSize, var entries, let listing):
                for index in entries.indices {
                    entries[index].setSourceKey(sourceKey)
                }
                value = .mangaList(ranking: ranking, pageSize: pageSize, entries: entries, listing: listing)
            case .mangaChapterList(let pageSize, var entries, let listing):
                for index in entries.indices {
                    entries[index].manga.sourceKey = sourceKey
                }
                value = .mangaChapterList(pageSize: pageSize, entries: entries, listing: listing)
            case .links(var links):
                for index in links.indices {
                    links[index].setSourceKey(sourceKey)
                }
                value = .links(links)
            case .filters:
                break
        }
    }
}

typealias PageContext = [String: String]
typealias ImageRef = Int32

struct Page: Hashable {
    var content: PageContent
    var thumbnail: URL?
    var hasDescription: Bool
    var description: String?
}

enum PageContent: Hashable {
    case url(url: URL, context: PageContext?)
    case text(String)
    case image(ImageRef)
    case zipFile(url: URL, filePath: String)
}

struct PageCodable: Hashable, Codable {
    let content: PageContentCodable
    @URLAsString var thumbnail: URL?
    let hasDescription: Bool
    let description: String?

    func into() -> Page? {
        guard let content = content.into() else { return nil }
        return Page(
            content: content,
            thumbnail: thumbnail,
            hasDescription: hasDescription,
            description: description
        )
    }
}

enum PageContentCodable: Hashable {
    case url(url: URL, context: PageContext?)
    case text(String)
    case image(ImageRef)
    case zipFile(url: URL, filePath: String)

    func into() -> PageContent? {
        switch self {
            case .url(let url, let context):
                return .url(url: url, context: context)
            case .text(let string):
                return .text(string)
            case .image(let imageRef):
                return .image(imageRef)
            case .zipFile(let url, let filePath):
                return .zipFile(url: url, filePath: filePath)
        }
    }
}

extension PageContentCodable: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(UInt8.self, forKey: .key)
        switch type {
            case 0:
                let urlString = try container.decode(String.self, forKey: .key)
                guard let url = URL(string: urlString) else { throw DecodingError.invalidUrl }
                let hasContext = try container.decode(UInt8.self, forKey: .key) == 1
                var context: PageContext?
                if hasContext {
                    var values = PageContext()
                    let count = try container.decode(UInt64.self, forKey: .key)
                    for _ in 0..<count {
                        let key = try container.decode(String.self, forKey: .key)
                        let value = try container.decode(String.self, forKey: .key)
                        values[key] = value
                    }
                    context = values
                }
                self = .url(url: url, context: context)
            case 1:
                self = .text(try container.decode(String.self, forKey: .key))
            case 2:
                self = .image(try container.decode(ImageRef.self, forKey: .key))
            case 3:
                let urlString = try container.decode(String.self, forKey: .key)
                guard let url = URL(string: urlString) else { throw DecodingError.invalidUrl }
                let filePath = try container.decode(String.self, forKey: .key)
                self = .zipFile(url: url, filePath: filePath)
            default:
                throw DecodingError.invalidContent
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
            case .url(let url, let context):
                try container.encode(UInt8(0), forKey: .key)
                try container.encode(url.absoluteString, forKey: .key)
                if let context = context {
                    try container.encode(UInt8(1), forKey: .key)
                    try container.encode(UInt64(context.count), forKey: .key)
                    for (key, value) in context {
                        try container.encode(key, forKey: .key)
                        try container.encode(value, forKey: .key)
                    }
                } else {
                    try container.encode(UInt8(0), forKey: .key)
                }
            case .text(let string):
                try container.encode(UInt8(1), forKey: .key)
                try container.encode(string, forKey: .key)
            case .image(let ref):
                try container.encode(UInt8(2), forKey: .key)
                try container.encode(ref, forKey: .key)
            case .zipFile(let url, let filePath):
                try container.encode(UInt8(3), forKey: .key)
                try container.encode(url.absoluteString, forKey: .key)
                try container.encode(filePath, forKey: .key)
        }
    }

    enum DecodingError: Error {
        case invalidContent
        case invalidUrl
    }

    enum CodingKeys: CodingKey {
        case key
    }
}
