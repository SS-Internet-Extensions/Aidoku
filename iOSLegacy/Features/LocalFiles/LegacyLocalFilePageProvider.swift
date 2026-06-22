//
//  LegacyLocalFilePageProvider.swift
//  AidokuLegacy
//
//  Turns a locally imported chapter into reader pages.
//
//  - cbz/zip/epub: returns one `.zipFile(url:filePath:)` page per sorted image
//    entry, so the existing LegacyZipPageResolver handles extraction (and the
//    reader's low-memory handling relocates bytes to temp files per page).
//  - pdf: renders each page to a JPEG in a temporary directory at a memory-safe
//    long-edge dimension (~1800px), suitable for a 1 GB iPad Air 1, and returns
//    `.url(fileURL)` pages.
//
//  iOS 12 / UIKit only: no Swift concurrency. The PDF path can block while
//  rendering, so callers pass it a background queue via `pages(for:on:completion:)`.
//

import Foundation
import PDFKit
import UIKit

enum LegacyLocalFilePageProvider {
    /// Maximum long-edge dimension (in pixels) for rendered PDF pages. Keeping
    /// this modest avoids large bitmap allocations on memory-constrained iPads.
    static let pdfMaxLongEdge: CGFloat = 1800
    /// JPEG quality for rendered PDF pages.
    static let pdfJPEGQuality: CGFloat = 0.82

    /// Synchronously builds reader pages for a chapter.
    ///
    /// For PDFs this performs rendering on the calling thread, so callers should
    /// invoke it from a background queue. For zip/cbz/epub it is cheap (no extraction).
    /// Returns an empty array if the archive is missing or unreadable.
    static func pages(for chapter: LegacyLocalChapter, mangaId: String) -> [AidokuRunnerLegacyPage] {
        guard let archiveURL = LegacyLocalFileStore.shared.archiveURL(mangaId: mangaId, chapter: chapter) else {
            return []
        }

        return pages(
            archiveURL: archiveURL,
            kind: chapter.kind,
            mangaId: mangaId,
            chapterId: chapter.id
        )
    }

    /// Builds reader pages from a concrete archive URL. Used by managed local
    /// files and by temporary self-hosted/OPDS downloads that should not be
    /// persisted into the local-files library.
    static func pages(
        archiveURL: URL,
        kind: LegacyLocalChapterKind,
        mangaId: String,
        chapterId: String
    ) -> [AidokuRunnerLegacyPage] {
        if kind.isZipContainer {
            return zipPages(archiveURL: archiveURL)
        } else {
            return pdfPages(archiveURL: archiveURL, mangaId: mangaId, chapterId: chapterId)
        }
    }

    /// Asynchronous convenience: runs `pages(for:mangaId:)` on `queue` and
    /// delivers the result on the main queue.
    static func pages(
        for chapter: LegacyLocalChapter,
        mangaId: String,
        on queue: DispatchQueue,
        completion: @escaping ([AidokuRunnerLegacyPage]) -> Void
    ) {
        queue.async {
            let result = pages(for: chapter, mangaId: mangaId)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    // MARK: - ZIP / CBZ

    private static func zipPages(archiveURL: URL) -> [AidokuRunnerLegacyPage] {
        let entries = LegacyLocalFileStore.sortedImageEntryPaths(in: archiveURL)
        return entries.map { entryPath in
            AidokuRunnerLegacyPage(
                content: .zipFile(url: archiveURL, filePath: entryPath),
                hasDescription: false,
                description: nil
            )
        }
    }

    // MARK: - PDF

    private static func pdfPages(archiveURL: URL, mangaId: String, chapterId: String) -> [AidokuRunnerLegacyPage] {
        guard let document = PDFDocument(url: archiveURL) else { return [] }
        let pageCount = document.pageCount
        guard pageCount > 0 else { return [] }

        let directory = renderDirectory(mangaId: mangaId, chapterId: chapterId)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return []
        }

        var pages: [AidokuRunnerLegacyPage] = []
        for index in 0..<pageCount {
            autoreleasepool {
                guard let pdfPage = document.page(at: index) else { return }
                let fileURL = directory.appendingPathComponent(String(format: "%04d.jpg", index))

                // Reuse an already-rendered page if it survived from a prior open.
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    pages.append(makeURLPage(fileURL))
                    return
                }

                guard let data = renderPageToJPEG(pdfPage) else { return }
                do {
                    try data.write(to: fileURL, options: .atomic)
                    pages.append(makeURLPage(fileURL))
                } catch {
                    // Skip pages that fail to persist; the reader shows a placeholder.
                }
            }
        }
        return pages
    }

    /// Renders a single PDF page to JPEG data, scaled so the long edge does not
    /// exceed `pdfMaxLongEdge`.
    private static func renderPageToJPEG(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let longEdge = max(bounds.width, bounds.height)
        let scale = longEdge > pdfMaxLongEdge ? (pdfMaxLongEdge / longEdge) : 1
        let pixelSize = CGSize(
            width: max(1, (bounds.width * scale).rounded()),
            height: max(1, (bounds.height * scale).rounded())
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)

        let image = renderer.image { context in
            let cgContext = context.cgContext
            // White background for transparent PDFs.
            UIColor.white.setFill()
            cgContext.fill(CGRect(origin: .zero, size: pixelSize))

            // PDFKit draws in a bottom-left origin coordinate space; flip and
            // scale into the destination bitmap.
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: pixelSize.height)
            cgContext.scaleBy(x: scale, y: -scale)
            cgContext.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            page.draw(with: .mediaBox, to: cgContext)
            cgContext.restoreGState()
        }

        return image.jpegData(compressionQuality: pdfJPEGQuality)
    }

    private static func makeURLPage(_ url: URL) -> AidokuRunnerLegacyPage {
        return AidokuRunnerLegacyPage(content: .url(url, context: nil), hasDescription: false, description: nil)
    }

    /// Temporary directory holding rendered PDF page images for a chapter.
    private static func renderDirectory(mangaId: String, chapterId: String) -> URL {
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AidokuLegacyLocalPDF", isDirectory: true)
            .appendingPathComponent(aidokuLegacySanitizedPathComponent(mangaId), isDirectory: true)
            .appendingPathComponent(aidokuLegacySanitizedPathComponent(chapterId), isDirectory: true)
    }

    /// Removes rendered PDF page images for a chapter (call when leaving the reader).
    static func clearRenderedPages(mangaId: String, chapterId: String) {
        let directory = renderDirectory(mangaId: mangaId, chapterId: chapterId)
        try? FileManager.default.removeItem(at: directory)
    }
}
