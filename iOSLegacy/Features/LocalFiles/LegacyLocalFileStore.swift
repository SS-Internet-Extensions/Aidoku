//
//  LegacyLocalFileStore.swift
//  AidokuLegacy
//
//  Persists locally imported archives (cbz/zip/pdf) under Application Support
//  and exposes them as Legacy* manga/chapter models. The store copies the
//  picked file into its own directory, determines a page count by listing
//  image entries (ZIPFoundation) or PDF pages (PDFKit), writes a JSON manifest,
//  and posts `.aidokuLegacyLocalFilesDidChange` so observers can refresh.
//
//  iOS 12 / UIKit only: no Swift concurrency. Work that may block (archive
//  inspection, file copies) runs on a private serial queue and reports back on
//  the main queue via a completion handler.
//

import Foundation
import PDFKit
import ZIPFoundation

extension Notification.Name {
    /// Posted whenever the set of imported local files changes (import/delete/clear).
    static let aidokuLegacyLocalFilesDidChange = Notification.Name("AidokuLegacyLocalFilesDidChange")
}

/// Errors surfaced while importing or reading a local archive.
enum LegacyLocalFileError: LocalizedError {
    case unreadableArchive
    case emptyArchive
    case copyFailed

    var errorDescription: String? {
        switch self {
            case .unreadableArchive:
                return "The selected file could not be opened as a CBZ, ZIP, or PDF."
            case .emptyArchive:
                return "The selected file did not contain any readable pages."
            case .copyFailed:
                return "The selected file could not be copied into local storage."
        }
    }
}

final class LegacyLocalFileStore {
    static let shared = LegacyLocalFileStore()

    private let fileManager = FileManager.default
    private let manifestFileName = "manifest.json"
    private let rootDirectoryName = "AidokuLegacyLocalFiles"
    private let queue = DispatchQueue(label: "AidokuLegacy.localFileStore", qos: .userInitiated)

    private init() {}

    // MARK: - Reading

    /// All imported manga, newest first.
    var mangaList: [LegacyLocalManga] {
        return manifests
            .map { $0.manga }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    /// The chapters belonging to the supplied manga (empty if unknown).
    func chapters(for manga: LegacyLocalManga) -> [LegacyLocalChapter] {
        return loadManifest(mangaId: manga.id)?.chapters ?? []
    }

    /// The absolute file URL of the archive backing a chapter, if it exists.
    func archiveURL(mangaId: String, chapter: LegacyLocalChapter) -> URL? {
        let url = mangaDirectory(mangaId: mangaId).appendingPathComponent(chapter.archiveFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// The absolute file URL of a manga's cover image, if one was extracted.
    func coverURL(for manga: LegacyLocalManga) -> URL? {
        guard let coverFileName = manga.coverFileName else { return nil }
        let url = mangaDirectory(mangaId: manga.id).appendingPathComponent(coverFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Importing

    /// Copies the archive at `url` into local storage, inspects it for a page
    /// count, writes a manifest, and returns the created manga/chapter.
    ///
    /// The completion fires on the main queue.
    func importArchive(
        at url: URL,
        completion: @escaping (Result<LegacyLocalMangaManifest, Error>) -> Void
    ) {
        // Security-scoped access is required for document-picker URLs.
        let didStartAccess = url.startAccessingSecurityScopedResource()

        queue.async { [weak self] in
            guard let self = self else { return }
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let result: Result<LegacyLocalMangaManifest, Error>
            do {
                result = .success(try self.performImport(at: url))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                if case .success = result {
                    NotificationCenter.default.post(name: .aidokuLegacyLocalFilesDidChange, object: nil)
                }
                completion(result)
            }
        }
    }

    /// Synchronous import body executed on the private queue.
    private func performImport(at url: URL) throws -> LegacyLocalMangaManifest {
        let pathExtension = url.pathExtension
        let kind = LegacyLocalChapterKind.from(pathExtension: pathExtension)
        let baseName = url.deletingPathExtension().lastPathComponent
        let title = baseName.isEmpty ? "Imported File" : baseName

        let mangaId = UUID().uuidString
        let directory = mangaDirectory(mangaId: mangaId)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        // Copy the archive in under a sanitized, stable name.
        let archiveExtension = pathExtension.isEmpty ? kindExtension(kind) : pathExtension
        let archiveFileName = "source." + aidokuLegacySanitizedPathComponent(archiveExtension)
        let archiveURL = directory.appendingPathComponent(archiveFileName)
        do {
            if fileManager.fileExists(atPath: archiveURL.path) {
                try fileManager.removeItem(at: archiveURL)
            }
            try fileManager.copyItem(at: url, to: archiveURL)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw LegacyLocalFileError.copyFailed
        }

        // Inspect the copied archive for a page count and optional cover.
        let inspection: (pageCount: Int, coverFileName: String?)
        do {
            inspection = try inspect(archiveURL: archiveURL, kind: kind, into: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        guard inspection.pageCount > 0 else {
            try? fileManager.removeItem(at: directory)
            throw LegacyLocalFileError.emptyArchive
        }

        let manga = LegacyLocalManga(
            id: mangaId,
            title: title,
            coverFileName: inspection.coverFileName,
            dateAdded: Date()
        )
        let chapter = LegacyLocalChapter(
            title: title,
            archiveFileName: archiveFileName,
            kind: kind,
            pageCount: inspection.pageCount
        )
        let manifest = LegacyLocalMangaManifest(manga: manga, chapters: [chapter])

        try writeManifest(manifest, mangaId: mangaId)
        return manifest
    }

    /// Determines the page count, and extracts a small cover image when cheap.
    private func inspect(
        archiveURL: URL,
        kind: LegacyLocalChapterKind,
        into directory: URL
    ) throws -> (pageCount: Int, coverFileName: String?) {
        if kind.isZipContainer {
            let entries = LegacyLocalFileStore.sortedImageEntryPaths(in: archiveURL)
            guard !entries.isEmpty else {
                // Distinguish an unreadable archive from a readable-but-empty one.
                guard Archive(url: archiveURL, accessMode: .read) != nil else {
                    throw LegacyLocalFileError.unreadableArchive
                }
                return (0, nil)
            }
            var coverFileName: String?
            if let first = entries.first,
               let data = LegacyZipPageResolver.extractEntry(from: archiveURL, filePath: first),
               !data.isEmpty {
                coverFileName = writeCover(data: data, suggestedExtension: (first as NSString).pathExtension, into: directory)
            }
            return (entries.count, coverFileName)
        } else {
            guard let document = PDFDocument(url: archiveURL) else {
                throw LegacyLocalFileError.unreadableArchive
            }
            return (document.pageCount, nil)
        }
    }

    /// Writes cover bytes to the manga directory and returns the relative name.
    private func writeCover(data: Data, suggestedExtension: String, into directory: URL) -> String? {
        let ext = suggestedExtension.isEmpty ? "img" : aidokuLegacySanitizedPathComponent(suggestedExtension)
        let fileName = "cover." + ext
        let url = directory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    // MARK: - Deleting

    /// Removes a single imported manga and its backing files.
    func delete(_ manga: LegacyLocalManga) {
        let directory = mangaDirectory(mangaId: manga.id)
        try? fileManager.removeItem(at: directory)
        NotificationCenter.default.post(name: .aidokuLegacyLocalFilesDidChange, object: nil)
    }

    /// Removes every imported manga.
    func clearAll() {
        if let root = try? localFilesDirectory() {
            try? fileManager.removeItem(at: root)
        }
        NotificationCenter.default.post(name: .aidokuLegacyLocalFilesDidChange, object: nil)
    }

    // MARK: - Manifest helpers

    private var manifests: [LegacyLocalMangaManifest] {
        guard
            let root = try? localFilesDirectory(),
            let entries = try? fileManager.contentsOfDirectory(atPath: root.path)
        else {
            return []
        }
        return entries.compactMap { mangaId in
            loadManifest(mangaId: mangaId)
        }
    }

    private func loadManifest(mangaId: String) -> LegacyLocalMangaManifest? {
        let url = mangaDirectory(mangaId: mangaId).appendingPathComponent(manifestFileName)
        guard
            let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(LegacyLocalMangaManifest.self, from: data)
        else {
            return nil
        }
        return manifest
    }

    private func writeManifest(_ manifest: LegacyLocalMangaManifest, mangaId: String) throws {
        let url = mangaDirectory(mangaId: mangaId).appendingPathComponent(manifestFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Directories

    private func localFilesDirectory() throws -> URL {
        let directory = try applicationSupportDirectory()
            .appendingPathComponent(rootDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    /// Resolves (and creates) the Application Support directory. Mirrors the
    /// file-private helper in LegacyRootViewController, which is not visible here.
    private func applicationSupportDirectory() throws -> URL {
        guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "AidokuLegacy",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Application Support is unavailable."]
            )
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    private func mangaDirectory(mangaId: String) -> URL {
        let root = (try? localFilesDirectory()) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root.appendingPathComponent(aidokuLegacySanitizedPathComponent(mangaId), isDirectory: true)
    }

    private func kindExtension(_ kind: LegacyLocalChapterKind) -> String {
        switch kind {
            case .cbz:
                return "cbz"
            case .zip:
                return "zip"
            case .pdf:
                return "pdf"
        }
    }

    // MARK: - Archive entry listing

    /// Lists image entry paths inside a ZIP/CBZ archive, sorted naturally so
    /// page order matches the on-disk numbering. Shared with the page provider.
    static func sortedImageEntryPaths(in archiveURL: URL) -> [String] {
        guard let archive = Archive(url: archiveURL, accessMode: .read) else { return [] }
        var paths: [String] = []
        for entry in archive {
            guard entry.type == .file else { continue }
            let path = entry.path
            // Skip directory markers, hidden files, and macOS metadata.
            let base = (path as NSString).lastPathComponent
            if base.hasPrefix(".") || base.hasPrefix("__MACOSX") { continue }
            if path.hasPrefix("__MACOSX/") { continue }
            guard isImagePath(path) else { continue }
            paths.append(path)
        }
        return paths.sorted { legacyLocalNaturalCompare($0, $1) }
    }

    /// Whether a path looks like a supported image based on its extension.
    static func isImagePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
            case "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "avif", "tiff", "tif":
                return true
            default:
                return false
        }
    }
}

/// Natural (numeric-aware) comparison so "page2" sorts before "page10".
func legacyLocalNaturalCompare(_ lhs: String, _ rhs: String) -> Bool {
    return lhs.compare(rhs, options: [.numeric, .caseInsensitive]) == .orderedAscending
}
