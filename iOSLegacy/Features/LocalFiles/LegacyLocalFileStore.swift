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
import Darwin
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
    private let watchedLocalFolderName = "Local"
    private let queue = DispatchQueue(label: "AidokuLegacy.localFileStore", qos: .userInitiated)
    private var folderSources: [String: DispatchSourceFileSystemObject] = [:]
    private var suppressFileEvents = false

    private init() {
        startFileSystemListener()
        scanLocalFolders()
    }

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
        let url: URL
        if let manifest = loadManifest(mangaId: mangaId), let localFolderPath = manifest.manga.localFolderPath {
            url = appendingRelativePath(chapter.archiveFileName, to: URL(fileURLWithPath: localFolderPath, isDirectory: true))
        } else {
            url = mangaDirectory(mangaId: mangaId).appendingPathComponent(chapter.archiveFileName)
        }
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

    /// Copies a selected structured folder into Documents/Local, then scans it.
    /// The completion fires on the main queue.
    func importFolder(
        at url: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let didStartAccess = url.startAccessingSecurityScopedResource()

        queue.async { [weak self] in
            guard let self = self else { return }
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let result: Result<Void, Error>
            do {
                try self.performFolderImport(at: url)
                _ = self.performLocalFolderScan()
                result = .success(())
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
            pageCount: inspection.pageCount,
            chapterNumber: 1
        )
        let manifest = LegacyLocalMangaManifest(manga: manga, chapters: [chapter])

        try writeManifest(manifest, mangaId: mangaId)
        return manifest
    }

    private func performFolderImport(at url: URL) throws {
        guard isDirectory(url), !localArchiveFiles(in: url).isEmpty else {
            throw LegacyLocalFileError.emptyArchive
        }
        guard let localFolder = watchedLocalFolder() else {
            throw LegacyLocalFileError.copyFailed
        }
        try fileManager.createDirectory(at: localFolder, withIntermediateDirectories: true, attributes: nil)

        let sourcePath = url.standardizedFileURL.path
        let destinationRoot = localFolder.standardizedFileURL.path
        if sourcePath.hasPrefix(destinationRoot + "/") {
            return
        }

        let baseName = url.lastPathComponent.isEmpty ? "Local Folder" : url.lastPathComponent
        var destination = localFolder.appendingPathComponent(baseName, isDirectory: true)
        var counter = 1
        while fileManager.fileExists(atPath: destination.path) {
            destination = localFolder.appendingPathComponent("\(baseName) (\(counter))", isDirectory: true)
            counter += 1
        }
        do {
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            throw LegacyLocalFileError.copyFailed
        }
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
        suppressFileEvents = true
        defer { suppressFileEvents = false }

        if let localFolderPath = manga.localFolderPath {
            try? fileManager.removeItem(atPath: localFolderPath)
        }
        let directory = mangaDirectory(mangaId: manga.id)
        try? fileManager.removeItem(at: directory)
        NotificationCenter.default.post(name: .aidokuLegacyLocalFilesDidChange, object: nil)
    }

    /// Removes a single chapter. If it was the last chapter, removes the manga too.
    func deleteChapter(mangaId: String, chapter: LegacyLocalChapter) {
        guard var manifest = loadManifest(mangaId: mangaId) else { return }
        suppressFileEvents = true
        defer { suppressFileEvents = false }

        if let archiveURL = archiveURL(mangaId: mangaId, chapter: chapter) {
            try? fileManager.removeItem(at: archiveURL)
        }
        LegacyLocalFilePageProvider.clearRenderedPages(mangaId: mangaId, chapterId: chapter.id)

        manifest.chapters.removeAll { $0.id == chapter.id }
        if manifest.chapters.isEmpty {
            try? fileManager.removeItem(at: mangaDirectory(mangaId: mangaId))
            if let localFolderPath = manifest.manga.localFolderPath {
                try? fileManager.removeItem(atPath: localFolderPath)
            }
        } else {
            try? writeManifest(manifest, mangaId: mangaId)
        }
        NotificationCenter.default.post(name: .aidokuLegacyLocalFilesDidChange, object: nil)
    }

    /// Removes every imported manga.
    func clearAll() {
        suppressFileEvents = true
        defer { suppressFileEvents = false }

        if let root = try? localFilesDirectory() {
            try? fileManager.removeItem(at: root)
        }
        if let localFolder = watchedLocalFolder() {
            try? fileManager.removeItem(at: localFolder)
        }
        NotificationCenter.default.post(name: .aidokuLegacyLocalFilesDidChange, object: nil)
    }

    // MARK: - Metadata

    func updateMangaMetadata(mangaId: String, title: String, description: String?) {
        guard var manifest = loadManifest(mangaId: mangaId) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        manifest.manga.title = trimmedTitle.isEmpty ? manifest.manga.title : trimmedTitle
        manifest.manga.description = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? writeManifest(manifest, mangaId: mangaId)
        NotificationCenter.default.post(name: .aidokuLegacyLocalFilesDidChange, object: nil)
    }

    func updateChapterMetadata(
        mangaId: String,
        chapterId: String,
        title: String,
        volumeNumber: Float?,
        chapterNumber: Float?
    ) {
        guard var manifest = loadManifest(mangaId: mangaId),
              let index = manifest.chapters.firstIndex(where: { $0.id == chapterId }) else {
            return
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        manifest.chapters[index].title = trimmedTitle.isEmpty ? manifest.chapters[index].title : trimmedTitle
        manifest.chapters[index].volumeNumber = volumeNumber
        manifest.chapters[index].chapterNumber = chapterNumber
        try? writeManifest(manifest, mangaId: mangaId)
        NotificationCenter.default.post(name: .aidokuLegacyLocalFilesDidChange, object: nil)
    }

    // MARK: - Watched Local Folder

    /// Scans Documents/Local for Mihon/Tachiyomi-style folders:
    /// Documents/Local/<Series>/**/*.cbz|zip|pdf.
    func scanLocalFolders() {
        guard !suppressFileEvents else { return }
        queue.async { [weak self] in
            guard let self = self, !self.suppressFileEvents else { return }
            let changed = self.performLocalFolderScan()
            DispatchQueue.main.async {
                if changed {
                    NotificationCenter.default.post(name: .aidokuLegacyLocalFilesDidChange, object: nil)
                }
            }
        }
    }

    private func performLocalFolderScan() -> Bool {
        guard let localFolder = watchedLocalFolder() else { return false }
        try? fileManager.createDirectory(at: localFolder, withIntermediateDirectories: true, attributes: nil)

        let folders = topLevelMangaFolders(in: localFolder)
        let watchedFolders = folders.flatMap { [$0] + childDirectories(in: $0) }
        refreshFileSystemListeners(for: [localFolder] + watchedFolders)

        let existing = manifests
            .filter { $0.manga.localFolderPath != nil }
            .reduce(into: [String: LegacyLocalMangaManifest]()) { result, manifest in
                result[manifest.manga.id] = manifest
            }

        var changed = false
        var scannedIds = Set<String>()

        for folder in folders {
            let mangaId = aidokuLegacySanitizedPathComponent(
                folder.lastPathComponent.precomposedStringWithCanonicalMapping
            )
            scannedIds.insert(mangaId)

            guard let manifest = buildScannedManifest(folder: folder, mangaId: mangaId, existing: existing[mangaId]) else {
                if existing[mangaId] != nil {
                    try? fileManager.removeItem(at: mangaDirectory(mangaId: mangaId))
                    changed = true
                }
                continue
            }

            if existing[mangaId] != manifest {
                do {
                    try writeManifest(manifest, mangaId: mangaId)
                    changed = true
                } catch {
                    // Keep the old manifest if the scan result cannot be saved.
                }
            }
        }

        for manifest in existing.values where !scannedIds.contains(manifest.manga.id) {
            try? fileManager.removeItem(at: mangaDirectory(mangaId: manifest.manga.id))
            changed = true
        }

        return changed
    }

    private func buildScannedManifest(
        folder: URL,
        mangaId: String,
        existing: LegacyLocalMangaManifest?
    ) -> LegacyLocalMangaManifest? {
        let archives = localArchiveFiles(in: folder).sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        guard !archives.isEmpty else { return nil }

        let manifestDirectory = mangaDirectory(mangaId: mangaId)
        try? fileManager.createDirectory(at: manifestDirectory, withIntermediateDirectories: true, attributes: nil)
        let existingChapters = (existing?.chapters ?? []).reduce(into: [String: LegacyLocalChapter]()) { result, chapter in
            result[chapter.archiveFileName] = chapter
        }

        var chapters: [LegacyLocalChapter] = []
        var coverFileName = existing?.manga.coverFileName
        for (index, archiveURL) in archives.enumerated() {
            let kind = LegacyLocalChapterKind.from(pathExtension: archiveURL.pathExtension)
            let relativePath = relativePath(for: archiveURL, in: folder)
            let inspection: (pageCount: Int, coverFileName: String?)
            do {
                inspection = try inspect(archiveURL: archiveURL, kind: kind, into: manifestDirectory)
            } catch {
                continue
            }
            guard inspection.pageCount > 0 else { continue }
            if coverFileName == nil {
                coverFileName = inspection.coverFileName
            }

            let existingChapter = existingChapters[relativePath]
            let chapterTitle = existingChapter?.title ?? archiveURL.deletingPathExtension().lastPathComponent
            let chapter = LegacyLocalChapter(
                id: existingChapter?.id ?? aidokuLegacySanitizedPathComponent(relativePath),
                title: chapterTitle,
                archiveFileName: relativePath,
                kind: kind,
                pageCount: inspection.pageCount,
                volumeNumber: existingChapter?.volumeNumber ?? inferVolumeNumber(from: archiveURL.lastPathComponent),
                chapterNumber: existingChapter?.chapterNumber
                    ?? inferChapterNumber(from: archiveURL.lastPathComponent)
                    ?? Float(index + 1)
            )
            chapters.append(chapter)
        }

        guard !chapters.isEmpty else { return nil }

        let manga = LegacyLocalManga(
            id: mangaId,
            title: existing?.manga.title ?? folder.lastPathComponent,
            coverFileName: coverFileName,
            description: existing?.manga.description,
            dateAdded: existing?.manga.dateAdded ?? Date(),
            localFolderPath: folder.path
        )
        return LegacyLocalMangaManifest(manga: manga, chapters: chapters)
    }

    private func topLevelMangaFolders(in localFolder: URL) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: localFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.filter { isDirectory($0) }.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func localArchiveFiles(in folder: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, !isDirectory(url), isSupportedLocalArchive(url) else { return nil }
            return url
        }
    }

    private func childDirectories(in folder: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, isDirectory(url) else { return nil }
            return url
        }
    }

    private func isSupportedLocalArchive(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
            case "cbz", "zip", "pdf":
                return true
            default:
                return false
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func relativePath(for url: URL, in folder: URL) -> String {
        let base = folder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }
        return url.lastPathComponent
    }

    private func appendingRelativePath(_ relativePath: String, to folder: URL) -> URL {
        var result = folder
        for component in relativePath.split(separator: "/") {
            result = result.appendingPathComponent(String(component))
        }
        return result
    }

    private func inferVolumeNumber(from fileName: String) -> Float? {
        return firstNumber(in: fileName, after: "(?i)\\b(vol(?:ume)?\\.?|v)")
    }

    private func inferChapterNumber(from fileName: String) -> Float? {
        return firstNumber(in: fileName, after: "(?i)\\b(ch(?:apter)?\\.?|c)")
    }

    private func firstNumber(in value: String, after prefixPattern: String) -> Float? {
        let pattern = prefixPattern + "\\s*[-_ ]*(\\d+(?:\\.\\d+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: value, options: [], range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 2,
              let range = Range(match.range(at: 2), in: value) else {
            return nil
        }
        return Float(String(value[range]))
    }

    // MARK: - File Listener

    private func startFileSystemListener() {
        guard let localFolder = watchedLocalFolder() else { return }
        try? fileManager.createDirectory(at: localFolder, withIntermediateDirectories: true, attributes: nil)
        watchDirectory(localFolder)
    }

    private func refreshFileSystemListeners(for folders: [URL]) {
        let expectedPaths = Set(folders.map { $0.standardizedFileURL.path })
        let stalePaths = folderSources.keys.filter { !expectedPaths.contains($0) }
        for path in stalePaths {
            folderSources[path]?.cancel()
            folderSources[path] = nil
        }
        for folder in folders {
            watchDirectory(folder)
        }
    }

    private func watchDirectory(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard folderSources[path] == nil else { return }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scanLocalFolders()
        }
        source.setCancelHandler {
            close(fd)
        }
        folderSources[path] = source
        source.resume()
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

    private func watchedLocalFolder() -> URL? {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent(watchedLocalFolderName, isDirectory: true)
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
