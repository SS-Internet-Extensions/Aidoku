//
//  AidokuRunnerLegacyPackageInstaller.swift
//  AidokuLegacy
//
//  Installs Aidoku .aix packages for the iOS 12 runner.
//

import Foundation
import ZIPFoundation

final class AidokuRunnerLegacyPackageInstaller {
    private let fileManager: FileManager
    private let backendFactory: AidokuRunnerLegacyBackendFactory

    init(
        fileManager: FileManager = .default,
        backendFactory: AidokuRunnerLegacyBackendFactory = UnavailableAidokuRunnerLegacyBackendFactory()
    ) {
        self.fileManager = fileManager
        self.backendFactory = backendFactory
    }

    func installPackage(at packageURL: URL) throws -> AidokuRunnerLegacySource {
        let stagingDirectory = try makeStagingDirectory()
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
        }

        try fileManager.unzipItem(at: packageURL, to: stagingDirectory)

        let payloadURL = stagingDirectory.appendingPathComponent("Payload")
        let sourceRoot = fileManager.fileExists(atPath: payloadURL.path) ? payloadURL : stagingDirectory
        let info = try loadSourceInfo(from: sourceRoot)
        let destination = try installedDirectory(for: info.info.id)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try fileManager.moveItem(at: sourceRoot, to: destination)

        return try AidokuRunnerLegacySource(
            installedSourceURL: destination,
            backendFactory: backendFactory
        )
    }

    func loadInstalledSources() -> [AidokuRunnerLegacySource] {
        guard let directory = try? sourcesDirectory(), fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries.compactMap {
            try? AidokuRunnerLegacySource(installedSourceURL: $0, backendFactory: backendFactory)
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func loadSourceInfo(from directory: URL) throws -> AidokuRunnerLegacySourceInfo {
        let infoURL = directory.appendingPathComponent("source.json")
        guard fileManager.fileExists(atPath: infoURL.path) else {
            throw AidokuRunnerLegacyError.missingSourceInfo
        }
        return try JSONDecoder().decode(AidokuRunnerLegacySourceInfo.self, from: Data(contentsOf: infoURL))
    }

    private func makeStagingDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AidokuRunnerLegacy-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    private func installedDirectory(for sourceKey: String) throws -> URL {
        return try sourcesDirectory().appendingPathComponent(sanitized(sourceKey), isDirectory: true)
    }

    private func sourcesDirectory() throws -> URL {
        guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AidokuRunnerLegacyError.invalidPackage
        }
        return supportDirectory.appendingPathComponent("AidokuRunnerLegacy", isDirectory: true)
    }

    private func sanitized(_ value: String) -> String {
        let dot = UnicodeScalar(".")
        let dash = UnicodeScalar("-")
        return value.unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == dot || scalar == dash {
                result.unicodeScalars.append(scalar)
            }
        }
    }
}
