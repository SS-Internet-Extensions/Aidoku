//
//  LegacyLocalFileModels.swift
//  AidokuLegacy
//
//  Codable models describing locally imported archives (cbz/zip/pdf) that
//  are read entirely on-device, without any network source. These mirror the
//  Legacy* naming used elsewhere in the iOS 12 fork and are persisted as a
//  JSON manifest under Application Support by LegacyLocalFileStore.
//

import Foundation

/// The archive container kind backing a locally imported chapter.
enum LegacyLocalChapterKind: String, Codable, Hashable {
    /// A comic book ZIP archive (`.cbz`).
    case cbz
    /// A plain ZIP archive (`.zip`).
    case zip
    /// A PDF document (`.pdf`).
    case pdf

    /// Whether the kind is backed by a ZIP container (handled by ZIPFoundation).
    var isZipContainer: Bool {
        switch self {
            case .cbz, .zip:
                return true
            case .pdf:
                return false
        }
    }

    /// Derives a kind from a file extension, defaulting to `.zip` for unknown
    /// archive-like inputs so generic data picks still import.
    static func from(pathExtension: String) -> LegacyLocalChapterKind {
        switch pathExtension.lowercased() {
            case "cbz":
                return .cbz
            case "pdf":
                return .pdf
            default:
                return .zip
        }
    }
}

/// A locally imported manga. Each imported archive currently maps to a single
/// manga that owns exactly one chapter, which keeps the import flow simple on
/// a memory-constrained device.
struct LegacyLocalManga: Codable, Hashable {
    /// Stable identifier; also used as the on-disk directory name (sanitized).
    let id: String
    /// User-facing title, derived from the imported file name.
    var title: String
    /// Optional cover image file name relative to the manga directory.
    var coverFileName: String?
    /// When the archive was imported.
    var dateAdded: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        coverFileName: String? = nil,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.coverFileName = coverFileName
        self.dateAdded = dateAdded
    }
}

/// A single chapter inside a locally imported manga, backed by one archive
/// file stored alongside the manifest.
struct LegacyLocalChapter: Codable, Hashable {
    /// Stable identifier within the owning manga.
    let id: String
    /// User-facing chapter title.
    var title: String
    /// Archive file name relative to the manga directory (e.g. "source.cbz").
    var archiveFileName: String
    /// The container kind backing this chapter.
    var kind: LegacyLocalChapterKind
    /// Number of readable pages discovered when the archive was imported.
    var pageCount: Int

    init(
        id: String = UUID().uuidString,
        title: String,
        archiveFileName: String,
        kind: LegacyLocalChapterKind,
        pageCount: Int
    ) {
        self.id = id
        self.title = title
        self.archiveFileName = archiveFileName
        self.kind = kind
        self.pageCount = pageCount
    }
}

/// On-disk manifest persisted as `manifest.json` inside each manga directory.
struct LegacyLocalMangaManifest: Codable, Hashable {
    var manga: LegacyLocalManga
    var chapters: [LegacyLocalChapter]

    init(manga: LegacyLocalManga, chapters: [LegacyLocalChapter]) {
        self.manga = manga
        self.chapters = chapters
    }
}
