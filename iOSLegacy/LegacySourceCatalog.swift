//
//  LegacySourceCatalog.swift
//  AidokuLegacy
//
//  iOS 12-compatible source list support for Aidoku Community Sources.
//

import Foundation

struct LegacySourceCatalog {
    static let communityIndexURL = URL(string: "https://aidoku-community.github.io/sources/index.min.json")!

    let url: URL
    let name: String
    let feedbackURL: URL?
    let sources: [LegacySourceInfo]
}

struct LegacySourceInfo: Decodable {
    let id: String
    let name: String
    let version: Int
    let iconURL: String?
    let downloadURL: String?
    let languages: [String]?
    let contentRating: Int?
    let altNames: [String]?
    let baseURL: String?
    let minAppVersion: String?
    let maxAppVersion: String?

    // Older source-list fields.
    let lang: String?
    let nsfw: Int?
    let file: String?
    let icon: String?

    private(set) var repositoryURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case iconURL
        case downloadURL
        case languages
        case contentRating
        case altNames
        case baseURL
        case minAppVersion
        case maxAppVersion
        case lang
        case nsfw
        case file
        case icon
    }

    var resolvedLanguages: [String] {
        return languages ?? lang.map { [$0] } ?? []
    }

    var languageText: String {
        let values = resolvedLanguages
        return values.isEmpty ? "multi" : values.joined(separator: ", ")
    }

    var ratingText: String {
        switch contentRating ?? nsfw ?? 0 {
            case 0:
                return "Safe"
            case 1:
                return "Suggestive"
            case 2:
                return "NSFW"
            default:
                return "Unknown"
        }
    }

    var displaySubtitle: String {
        return "\(id)  v\(version)  \(languageText)"
    }

    var resolvedDownloadURL: URL? {
        guard let repositoryURL = repositoryURL else { return nil }
        if let downloadURL = downloadURL {
            return URL(string: downloadURL, relativeTo: repositoryURL)?.absoluteURL
        }
        if let file = file {
            return URL(string: "sources/\(file)", relativeTo: repositoryURL)?.absoluteURL
        }
        return nil
    }

    var resolvedIconURL: URL? {
        guard let repositoryURL = repositoryURL else { return nil }
        if let iconURL = iconURL {
            return URL(string: iconURL, relativeTo: repositoryURL)?.absoluteURL
        }
        if let icon = icon {
            return URL(string: "icons/\(icon)", relativeTo: repositoryURL)?.absoluteURL
        }
        return nil
    }

    func with(repositoryURL: URL) -> LegacySourceInfo {
        var copy = self
        copy.repositoryURL = repositoryURL
        return copy
    }

    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }

        let needle = trimmed.lowercased()
        if name.lowercased().contains(needle) || id.lowercased().contains(needle) {
            return true
        }
        if resolvedLanguages.contains(where: { $0.lowercased().contains(needle) }) {
            return true
        }
        return altNames?.contains(where: { $0.lowercased().contains(needle) }) ?? false
    }
}

final class LegacySourceCatalogClient {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    @discardableResult
    func fetchCatalog(
        from url: URL = LegacySourceCatalog.communityIndexURL,
        completion: @escaping (Result<LegacySourceCatalog, Error>) -> Void
    ) -> URLSessionDataTask {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let task = session.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(LegacySourceCatalogError.emptyResponse))
                return
            }

            do {
                completion(.success(try Self.decodeCatalog(data: data, url: url)))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
        return task
    }

    @discardableResult
    func downloadPackage(
        for source: LegacySourceInfo,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> URLSessionDownloadTask? {
        guard let url = source.resolvedDownloadURL else {
            completion(.failure(LegacySourceCatalogError.missingPackageURL))
            return nil
        }

        let task = session.downloadTask(with: URLRequest(url: url)) { location, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let location = location else {
                completion(.failure(LegacySourceCatalogError.emptyResponse))
                return
            }

            do {
                let destination = try Self.packageDestination(for: source)
                let directory = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: location, to: destination)
                completion(.success(destination))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
        return task
    }

    private static func decodeCatalog(data: Data, url: URL) throws -> LegacySourceCatalog {
        if let modern = try? JSONDecoder().decode(CodableLegacySourceCatalog.self, from: data) {
            return modern.into(url: url)
        }

        let legacySources = try JSONDecoder().decode([LegacySourceInfo].self, from: data)
        return LegacySourceCatalog(
            url: url,
            name: "Legacy Source List",
            feedbackURL: nil,
            sources: legacySources.map { $0.with(repositoryURL: url) }
        )
    }

    private static func packageDestination(for source: LegacySourceInfo) throws -> URL {
        guard let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LegacySourceCatalogError.missingApplicationSupportDirectory
        }
        let dot = UnicodeScalar(".")!
        let dash = UnicodeScalar("-")!
        let safeId = source.id.unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == dot || scalar == dash {
                result.unicodeScalars.append(scalar)
            }
        }
        return supportDirectory
            .appendingPathComponent("LegacySources", isDirectory: true)
            .appendingPathComponent("\(safeId)-v\(source.version).aix")
    }
}

private struct CodableLegacySourceCatalog: Decodable {
    let name: String
    let feedbackURL: String?
    let sources: [LegacySourceInfo]

    func into(url: URL) -> LegacySourceCatalog {
        return LegacySourceCatalog(
            url: url,
            name: name,
            feedbackURL: feedbackURL.flatMap(URL.init),
            sources: sources.map { $0.with(repositoryURL: url) }
        )
    }
}

enum LegacySourceCatalogError: LocalizedError {
    case emptyResponse
    case missingApplicationSupportDirectory
    case missingPackageURL

    var errorDescription: String? {
        switch self {
            case .emptyResponse:
                return "The source list response was empty."
            case .missingApplicationSupportDirectory:
                return "The Application Support directory is unavailable."
            case .missingPackageURL:
                return "This source does not include a package URL."
        }
    }
}
