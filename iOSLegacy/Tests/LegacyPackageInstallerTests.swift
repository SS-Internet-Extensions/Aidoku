//
//  LegacyPackageInstallerTests.swift
//  AidokuLegacyTests
//
//  Installing .aix packages through AidokuRunnerLegacyPackageInstaller.
//

import XCTest
import ZIPFoundation
@testable import AidokuLegacy

final class LegacyPackageInstallerTests: XCTestCase {
    private var installer: AidokuRunnerLegacyPackageInstaller!
    private var tempRoots: [URL] = []
    private var installedKeys: [String] = []

    override func setUp() {
        super.setUp()
        installer = AidokuRunnerLegacyPackageInstaller(
            backendFactory: FakeLegacyBackendFactory()
        )
    }

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
        // Clean installed sources written under Application Support.
        for key in installedKeys {
            if let dir = installedSourceDirectory(for: key) {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        installedKeys = []
        installer = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func installedSourceDirectory(for key: String) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support
            .appendingPathComponent("AidokuRunnerLegacy", isDirectory: true)
            .appendingPathComponent(aidokuLegacySanitizedPathComponent(key), isDirectory: true)
    }

    /// Writes the given files into a fresh directory and zips it into an `.aix`.
    private func makePackage(
        files: [String: Data],
        wrapInPayload: Bool = false
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyPkg-\(UUID().uuidString)", isDirectory: true)
        tempRoots.append(root)
        let contentRoot = wrapInPayload ? root.appendingPathComponent("Payload", isDirectory: true) : root
        try FileManager.default.createDirectory(at: contentRoot, withIntermediateDirectories: true)
        for (name, data) in files {
            try data.write(to: contentRoot.appendingPathComponent(name))
        }
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyPkg-\(UUID().uuidString).aix")
        tempRoots.append(zipURL)
        // shouldKeepParent: false keeps entries at the archive root, matching the
        // installer's expectation of `source.json`/`Payload/source.json` at top level.
        try FileManager.default.zipItem(at: root, to: zipURL, shouldKeepParent: false)
        return zipURL
    }

    private func validFiles(id: String = "test.installer", version: Int = 5) -> [String: Data] {
        [
            "source.json": LegacyFixtures.sourceJSON(id: id, name: "Installed", version: version),
            "main.wasm": Data([0x00, 0x61, 0x73, 0x6d])
        ]
    }

    // MARK: - Tests

    func testInstallsValidPackage() throws {
        let id = "test.installer.valid"
        installedKeys.append(id)
        let packageURL = try makePackage(files: validFiles(id: id, version: 7))

        let source = try installer.installPackage(at: packageURL)

        XCTAssertEqual(source.key, id)
        XCTAssertEqual(source.name, "Installed")
        XCTAssertEqual(source.version, 7)
        XCTAssertEqual(source.languages, ["en"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.url.appendingPathComponent("main.wasm").path))
    }

    func testInstallsPackageWrappedInPayloadDirectory() throws {
        let id = "test.installer.payload"
        installedKeys.append(id)
        let packageURL = try makePackage(files: validFiles(id: id), wrapInPayload: true)

        let source = try installer.installPackage(at: packageURL)

        XCTAssertEqual(source.key, id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.url.appendingPathComponent("source.json").path))
    }

    func testLoadInstalledSourcesReturnsInstalledPackage() throws {
        let id = "test.installer.loaded"
        installedKeys.append(id)
        _ = try installer.installPackage(at: try makePackage(files: validFiles(id: id)))

        let loaded = installer.loadInstalledSources()
        XCTAssertTrue(loaded.contains { $0.key == id })
    }

    func testInstallFailsWhenExecutableMissing() throws {
        // source.json validates and the package is staged before the facade rejects
        // the missing executable, so register the key for teardown cleanup.
        installedKeys.append("test.installer.noexec")
        let packageURL = try makePackage(files: [
            "source.json": LegacyFixtures.sourceJSON(id: "test.installer.noexec")
        ])
        XCTAssertThrowsError(try installer.installPackage(at: packageURL)) { error in
            XCTAssertEqual(error as? AidokuRunnerLegacyError, .missingExecutable)
        }
    }

    func testInstallFailsWhenSourceInfoMissing() throws {
        let packageURL = try makePackage(files: [
            "main.wasm": Data([0x00, 0x61, 0x73, 0x6d])
        ])
        XCTAssertThrowsError(try installer.installPackage(at: packageURL)) { error in
            XCTAssertEqual(error as? AidokuRunnerLegacyError, .missingSourceInfo)
        }
    }
}

extension AidokuRunnerLegacyError: Equatable {
    static func == (lhs: AidokuRunnerLegacyError, rhs: AidokuRunnerLegacyError) -> Bool {
        switch (lhs, rhs) {
            case (.invalidPackage, .invalidPackage),
                 (.missingSourceInfo, .missingSourceInfo),
                 (.missingExecutable, .missingExecutable),
                 (.backendUnavailable, .backendUnavailable):
                return true
            default:
                return false
        }
    }
}
