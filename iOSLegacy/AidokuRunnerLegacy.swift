//
//  AidokuRunnerLegacy.swift
//  AidokuLegacy
//
//  Local iOS 12-compatible source runner facade.
//

import Foundation

final class AidokuRunnerLegacySource {
    let url: URL
    let key: String
    let name: String
    let version: Int
    let languages: [String]
    let urls: [URL]
    let contentRating: AidokuRunnerLegacySourceContentRating
    let imageUrl: URL?
    let config: AidokuRunnerLegacySourceInfo.Configuration?
    let staticListings: [AidokuRunnerLegacyListing]
    let runner: AidokuRunnerLegacyRunner

    init(
        url: URL,
        info: AidokuRunnerLegacySourceInfo,
        runner: AidokuRunnerLegacyRunner
    ) {
        let sourceInfo = info.info
        self.url = url
        self.key = sourceInfo.id
        self.name = sourceInfo.name
        self.version = sourceInfo.version
        self.languages = sourceInfo.languages
        self.contentRating = sourceInfo.contentRating ?? .safe
        self.config = info.config
        self.staticListings = info.listings ?? []
        self.imageUrl = Self.iconURL(in: url)

        var baseUrls = [URL]()
        if let urlString = sourceInfo.url, let url = URL(string: urlString) {
            baseUrls.append(url)
        }
        if let sourceUrls = sourceInfo.urls {
            baseUrls.append(contentsOf: sourceUrls.compactMap { URL(string: $0) })
        }
        self.urls = baseUrls
        self.runner = runner
    }

    convenience init(
        installedSourceURL: URL,
        backendFactory: AidokuRunnerLegacyBackendFactory = UnavailableAidokuRunnerLegacyBackendFactory()
    ) throws {
        let infoURL = installedSourceURL.appendingPathComponent("source.json")
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            throw AidokuRunnerLegacyError.missingSourceInfo
        }

        let executableURL = installedSourceURL.appendingPathComponent("main.wasm")
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw AidokuRunnerLegacyError.missingExecutable
        }

        let sourceInfo = try JSONDecoder().decode(
            AidokuRunnerLegacySourceInfo.self,
            from: Data(contentsOf: infoURL)
        )
        let runner = try backendFactory.makeRunner(sourceURL: installedSourceURL, info: sourceInfo)
        self.init(url: installedSourceURL, info: sourceInfo, runner: runner)
    }

    var supportsListings: Bool {
        return runner.features.providesListings || !staticListings.isEmpty
    }

    private static func iconURL(in sourceURL: URL) -> URL? {
        let lowercaseIcon = sourceURL.appendingPathComponent("icon.png")
        if FileManager.default.fileExists(atPath: lowercaseIcon.path) {
            return lowercaseIcon
        }

        let uppercaseIcon = sourceURL.appendingPathComponent("Icon.png")
        if FileManager.default.fileExists(atPath: uppercaseIcon.path) {
            return uppercaseIcon
        }

        return nil
    }
}

protocol AidokuRunnerLegacyBackendFactory {
    func makeRunner(
        sourceURL: URL,
        info: AidokuRunnerLegacySourceInfo
    ) throws -> AidokuRunnerLegacyRunner
}

struct UnavailableAidokuRunnerLegacyBackendFactory: AidokuRunnerLegacyBackendFactory {
    func makeRunner(
        sourceURL: URL,
        info: AidokuRunnerLegacySourceInfo
    ) throws -> AidokuRunnerLegacyRunner {
        return AidokuRunnerLegacyUnavailableRunner()
    }
}
