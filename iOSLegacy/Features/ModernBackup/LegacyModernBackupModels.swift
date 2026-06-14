//
//  LegacyModernBackupModels.swift
//  AidokuLegacy
//
//  Codable structs mirroring the modern Aidoku backup JSON schema.
//
//  These intentionally reproduce the field names used by the modern Aidoku
//  `Backup` model (see Shared/Data/Backup/Models in the main app) so that real
//  modern backups decode here, and so the JSON we emit can be read back by a
//  modern Aidoku install. The legacy app only supports a subset of the modern
//  feature set, so decoding is deliberately tolerant: every field is optional
//  where the modern format allows it, and we fall back to sensible defaults.
//
//  Date handling: modern JSON backups are decoded by the main app using
//  `JSONDecoder` with `.secondsSince1970`. We mirror that strategy in the
//  importer/exporter so `Date` fields round-trip correctly.
//

import Foundation

// MARK: - Root

// Mirrors the modern `Backup` struct. Only the members the legacy app can act
// on are modelled; unknown members in a real backup are ignored on decode and
// omitted on encode.
struct LegacyModernBackup: Codable {
    var library: [LegacyModernBackupLibraryManga]?
    var history: [LegacyModernBackupHistory]?
    var manga: [LegacyModernBackupManga]?
    var chapters: [LegacyModernBackupChapter]?
    var updates: [LegacyModernBackupUpdate]?
    var categories: [LegacyModernBackupCategory]?
    var sources: [LegacyModernBackupSource]?
    var sourceLists: [String]?
    var date: Date
    var name: String?
    var automatic: Bool?
    var version: String?

    init(
        library: [LegacyModernBackupLibraryManga]? = nil,
        history: [LegacyModernBackupHistory]? = nil,
        manga: [LegacyModernBackupManga]? = nil,
        chapters: [LegacyModernBackupChapter]? = nil,
        updates: [LegacyModernBackupUpdate]? = nil,
        categories: [LegacyModernBackupCategory]? = nil,
        sources: [LegacyModernBackupSource]? = nil,
        sourceLists: [String]? = nil,
        date: Date,
        name: String? = nil,
        automatic: Bool? = nil,
        version: String? = nil
    ) {
        self.library = library
        self.history = history
        self.manga = manga
        self.chapters = chapters
        self.updates = updates
        self.categories = categories
        self.sources = sources
        self.sourceLists = sourceLists
        self.date = date
        self.name = name
        self.automatic = automatic
        self.version = version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        library = try container.decodeIfPresent([LegacyModernBackupLibraryManga].self, forKey: .library)
        history = try container.decodeIfPresent([LegacyModernBackupHistory].self, forKey: .history)
        manga = try container.decodeIfPresent([LegacyModernBackupManga].self, forKey: .manga)
        chapters = try container.decodeIfPresent([LegacyModernBackupChapter].self, forKey: .chapters)
        updates = try container.decodeIfPresent([LegacyModernBackupUpdate].self, forKey: .updates)
        categories = try container.decodeIfPresent([LegacyModernBackupCategory].self, forKey: .categories)
        sources = try container.decodeIfPresent([LegacyModernBackupSource].self, forKey: .sources)
        sourceLists = try container.decodeIfPresent([String].self, forKey: .sourceLists)
        // `date` is required in the modern format, but be tolerant: fall back to
        // the current date if a malformed backup omits it.
        date = (try? container.decodeIfPresent(Date.self, forKey: .date)) ?? Date()
        name = try container.decodeIfPresent(String.self, forKey: .name)
        automatic = try container.decodeIfPresent(Bool.self, forKey: .automatic)
        version = try container.decodeIfPresent(String.self, forKey: .version)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(library, forKey: .library)
        try container.encodeIfPresent(history, forKey: .history)
        try container.encodeIfPresent(manga, forKey: .manga)
        try container.encodeIfPresent(chapters, forKey: .chapters)
        try container.encodeIfPresent(updates, forKey: .updates)
        try container.encodeIfPresent(categories, forKey: .categories)
        try container.encodeIfPresent(sources, forKey: .sources)
        try container.encodeIfPresent(sourceLists, forKey: .sourceLists)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(automatic, forKey: .automatic)
        try container.encodeIfPresent(version, forKey: .version)
    }

    enum CodingKeys: String, CodingKey {
        case library
        case history
        case manga
        case chapters
        case updates
        case categories
        case sources
        case sourceLists
        case date
        case name
        case automatic
        case version
    }
}

// MARK: - Library

// Mirrors the modern `BackupLibraryManga`. Library rows reference manga by the
// (`sourceId`, `mangaId`) pair; the manga payload lives in the top-level
// `manga` array.
struct LegacyModernBackupLibraryManga: Codable {
    var lastOpened: Date?
    var lastUpdated: Date?
    var lastUpdatedChapters: Date?
    var lastChapter: Date?
    var lastRead: Date?
    var dateAdded: Date?
    var categories: [String]?
    var mangaId: String
    var sourceId: String

    init(
        lastOpened: Date? = nil,
        lastUpdated: Date? = nil,
        lastUpdatedChapters: Date? = nil,
        lastChapter: Date? = nil,
        lastRead: Date? = nil,
        dateAdded: Date? = nil,
        categories: [String]? = nil,
        mangaId: String,
        sourceId: String
    ) {
        self.lastOpened = lastOpened
        self.lastUpdated = lastUpdated
        self.lastUpdatedChapters = lastUpdatedChapters
        self.lastChapter = lastChapter
        self.lastRead = lastRead
        self.dateAdded = dateAdded
        self.categories = categories
        self.mangaId = mangaId
        self.sourceId = sourceId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastOpened = try container.decodeIfPresent(Date.self, forKey: .lastOpened)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        lastUpdatedChapters = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedChapters)
        lastChapter = try container.decodeIfPresent(Date.self, forKey: .lastChapter)
        lastRead = try container.decodeIfPresent(Date.self, forKey: .lastRead)
        dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded)
        categories = try container.decodeIfPresent([String].self, forKey: .categories)
        mangaId = try container.decodeIfPresent(String.self, forKey: .mangaId) ?? ""
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId) ?? ""
    }
}

// MARK: - History

// Mirrors the modern `BackupHistory`. References a chapter/manga by id; the
// chapter and manga payloads live in the top-level `chapters` / `manga` arrays.
struct LegacyModernBackupHistory: Codable {
    var dateRead: Date?
    var sourceId: String
    var chapterId: String
    var mangaId: String
    var progress: Int?
    var total: Int?
    var completed: Bool?

    init(
        dateRead: Date? = nil,
        sourceId: String,
        chapterId: String,
        mangaId: String,
        progress: Int? = nil,
        total: Int? = nil,
        completed: Bool? = nil
    ) {
        self.dateRead = dateRead
        self.sourceId = sourceId
        self.chapterId = chapterId
        self.mangaId = mangaId
        self.progress = progress
        self.total = total
        self.completed = completed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dateRead = try container.decodeIfPresent(Date.self, forKey: .dateRead)
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId) ?? ""
        chapterId = try container.decodeIfPresent(String.self, forKey: .chapterId) ?? ""
        mangaId = try container.decodeIfPresent(String.self, forKey: .mangaId) ?? ""
        progress = try container.decodeIfPresent(Int.self, forKey: .progress)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed)
    }
}

// MARK: - Manga

// Mirrors the modern `BackupManga`. Carries the full manga metadata keyed by
// (`sourceId`, `id`). Numeric enum fields (`status`, `nsfw`, `viewer`) are
// preserved for round-trip but not otherwise interpreted by the legacy app.
struct LegacyModernBackupManga: Codable {
    var id: String
    var sourceId: String
    var title: String
    var author: String?
    var artist: String?
    var desc: String?
    var tags: [String]?
    var cover: String?
    var url: String?
    var status: Int?
    var nsfw: Int?
    var viewer: Int?
    var nextUpdateTime: Date?
    var chapterFlags: Int?
    var langFilter: String?
    var scanlatorFilter: [String]?

    init(
        id: String,
        sourceId: String,
        title: String,
        author: String? = nil,
        artist: String? = nil,
        desc: String? = nil,
        tags: [String]? = nil,
        cover: String? = nil,
        url: String? = nil,
        status: Int? = nil,
        nsfw: Int? = nil,
        viewer: Int? = nil,
        nextUpdateTime: Date? = nil,
        chapterFlags: Int? = nil,
        langFilter: String? = nil,
        scanlatorFilter: [String]? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.title = title
        self.author = author
        self.artist = artist
        self.desc = desc
        self.tags = tags
        self.cover = cover
        self.url = url
        self.status = status
        self.nsfw = nsfw
        self.viewer = viewer
        self.nextUpdateTime = nextUpdateTime
        self.chapterFlags = chapterFlags
        self.langFilter = langFilter
        self.scanlatorFilter = scanlatorFilter
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        desc = try container.decodeIfPresent(String.self, forKey: .desc)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        status = try container.decodeIfPresent(Int.self, forKey: .status)
        nsfw = try container.decodeIfPresent(Int.self, forKey: .nsfw)
        viewer = try container.decodeIfPresent(Int.self, forKey: .viewer)
        nextUpdateTime = try container.decodeIfPresent(Date.self, forKey: .nextUpdateTime)
        chapterFlags = try container.decodeIfPresent(Int.self, forKey: .chapterFlags)
        langFilter = try container.decodeIfPresent(String.self, forKey: .langFilter)
        scanlatorFilter = try container.decodeIfPresent([String].self, forKey: .scanlatorFilter)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceId, forKey: .sourceId)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(artist, forKey: .artist)
        try container.encodeIfPresent(desc, forKey: .desc)
        try container.encodeIfPresent(tags, forKey: .tags)
        try container.encodeIfPresent(cover, forKey: .cover)
        try container.encodeIfPresent(url, forKey: .url)
        // The modern format treats these as non-optional Int; emit defaults so a
        // modern decode never fails on a missing key.
        try container.encode(status ?? 0, forKey: .status)
        try container.encode(nsfw ?? 0, forKey: .nsfw)
        try container.encode(viewer ?? 0, forKey: .viewer)
        try container.encodeIfPresent(nextUpdateTime, forKey: .nextUpdateTime)
        try container.encodeIfPresent(chapterFlags, forKey: .chapterFlags)
        try container.encodeIfPresent(langFilter, forKey: .langFilter)
        try container.encodeIfPresent(scanlatorFilter, forKey: .scanlatorFilter)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sourceId
        case title
        case author
        case artist
        case desc
        case tags
        case cover
        case url
        case status
        case nsfw
        case viewer
        case nextUpdateTime
        case chapterFlags
        case langFilter
        case scanlatorFilter
    }
}

// MARK: - Chapter

// Mirrors the modern `BackupChapter`. Keyed by (`sourceId`, `mangaId`, `id`).
struct LegacyModernBackupChapter: Codable {
    var sourceId: String
    var mangaId: String
    var id: String
    var title: String?
    var scanlator: String?
    var url: String?
    var lang: String?
    var chapter: Float?
    var volume: Float?
    var dateUploaded: Date?
    var thumbnail: String?
    var locked: Bool?
    var sourceOrder: Int?

    init(
        sourceId: String,
        mangaId: String,
        id: String,
        title: String? = nil,
        scanlator: String? = nil,
        url: String? = nil,
        lang: String? = nil,
        chapter: Float? = nil,
        volume: Float? = nil,
        dateUploaded: Date? = nil,
        thumbnail: String? = nil,
        locked: Bool? = nil,
        sourceOrder: Int? = nil
    ) {
        self.sourceId = sourceId
        self.mangaId = mangaId
        self.id = id
        self.title = title
        self.scanlator = scanlator
        self.url = url
        self.lang = lang
        self.chapter = chapter
        self.volume = volume
        self.dateUploaded = dateUploaded
        self.thumbnail = thumbnail
        self.locked = locked
        self.sourceOrder = sourceOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId) ?? ""
        mangaId = try container.decodeIfPresent(String.self, forKey: .mangaId) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title)
        scanlator = try container.decodeIfPresent(String.self, forKey: .scanlator)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        lang = try container.decodeIfPresent(String.self, forKey: .lang)
        chapter = try container.decodeIfPresent(Float.self, forKey: .chapter)
        volume = try container.decodeIfPresent(Float.self, forKey: .volume)
        dateUploaded = try container.decodeIfPresent(Date.self, forKey: .dateUploaded)
        thumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnail)
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked)
        sourceOrder = try container.decodeIfPresent(Int.self, forKey: .sourceOrder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceId, forKey: .sourceId)
        try container.encode(mangaId, forKey: .mangaId)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(scanlator, forKey: .scanlator)
        try container.encodeIfPresent(url, forKey: .url)
        // Modern format treats `lang` as non-optional; emit a default.
        try container.encode(lang ?? "", forKey: .lang)
        try container.encodeIfPresent(chapter, forKey: .chapter)
        try container.encodeIfPresent(volume, forKey: .volume)
        try container.encodeIfPresent(dateUploaded, forKey: .dateUploaded)
        try container.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try container.encodeIfPresent(locked, forKey: .locked)
        // Modern format treats `sourceOrder` as non-optional; emit a default.
        try container.encode(sourceOrder ?? 0, forKey: .sourceOrder)
    }

    enum CodingKeys: String, CodingKey {
        case sourceId
        case mangaId
        case id
        case title
        case scanlator
        case url
        case lang
        case chapter
        case volume
        case dateUploaded
        case thumbnail
        case locked
        case sourceOrder
    }
}

// MARK: - Update

// Mirrors the modern `BackupUpdate`. References manga/chapter by id.
struct LegacyModernBackupUpdate: Codable {
    var date: Date?
    var viewed: Bool?
    var sourceId: String
    var mangaId: String
    var chapterId: String

    init(
        date: Date? = nil,
        viewed: Bool? = nil,
        sourceId: String,
        mangaId: String,
        chapterId: String
    ) {
        self.date = date
        self.viewed = viewed
        self.sourceId = sourceId
        self.mangaId = mangaId
        self.chapterId = chapterId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeIfPresent(Date.self, forKey: .date)
        viewed = try container.decodeIfPresent(Bool.self, forKey: .viewed)
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId) ?? ""
        mangaId = try container.decodeIfPresent(String.self, forKey: .mangaId) ?? ""
        chapterId = try container.decodeIfPresent(String.self, forKey: .chapterId) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(date, forKey: .date)
        try container.encode(viewed ?? false, forKey: .viewed)
        try container.encode(sourceId, forKey: .sourceId)
        try container.encode(mangaId, forKey: .mangaId)
        try container.encode(chapterId, forKey: .chapterId)
    }

    enum CodingKeys: String, CodingKey {
        case date
        case viewed
        case sourceId
        case mangaId
        case chapterId
    }
}

// MARK: - Category

// Mirrors the modern `BackupCategory`, which encodes either as a bare string or
// as an object with a `title`. We mirror that behaviour: decode from either
// shape and always encode as a bare string (the only field the legacy app uses).
struct LegacyModernBackupCategory: Codable {
    var title: String?
    var sort: Int?
    var group: Bool?

    init(title: String?, sort: Int? = nil, group: Bool? = nil) {
        self.title = title
        self.sort = sort
        self.group = group
    }

    init(from decoder: Decoder) throws {
        // First try a bare string.
        let single = try decoder.singleValueContainer()
        if let title = try? single.decode(String.self) {
            self.title = title
            self.sort = nil
            self.group = nil
            return
        }
        // Otherwise decode as an object.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        sort = try? container.decodeIfPresent(Int.self, forKey: .sort)
        group = try? container.decodeIfPresent(Bool.self, forKey: .group)
    }

    func encode(to encoder: Encoder) throws {
        // Encode as a bare string for maximum compatibility with both the modern
        // string and object decoders.
        var container = encoder.singleValueContainer()
        try container.encode(title ?? "")
    }

    enum CodingKeys: String, CodingKey {
        case title
        case sort
        case group
    }
}

// MARK: - Source

// Mirrors the modern `BackupSource`, which encodes as either a bare source-id
// string or an object with `id`/`apiVersion`/`config`. The legacy app only acts
// on the `id`; we decode from either shape and always encode as a bare string.
struct LegacyModernBackupSource: Codable {
    var id: String

    init(id: String) {
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let id = try? single.decode(String.self) {
            self.id = id
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case apiVersion
        case config
    }
}
