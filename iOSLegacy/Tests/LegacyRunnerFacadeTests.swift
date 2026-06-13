//
//  LegacyRunnerFacadeTests.swift
//  AidokuLegacyTests
//
//  AidokuRunnerLegacySource facade behavior and runner call routing.
//

import XCTest
@testable import AidokuLegacy

final class LegacyRunnerFacadeTests: XCTestCase {
    // MARK: - Capability flags

    func testSupportsListingsFromRunnerFeature() {
        var features = AidokuRunnerLegacySourceFeatures.none()
        features.providesListings = true
        let source = LegacyFixtures.source(runner: FakeLegacyRunner(features: features))
        XCTAssertTrue(source.supportsListings)
    }

    func testDoesNotSupportListingsWhenNoneAvailable() {
        let source = LegacyFixtures.source(runner: FakeLegacyRunner(features: .none()))
        XCTAssertFalse(source.supportsListings)
        XCTAssertFalse(source.hasConfigurableSettings)
    }

    func testHasConfigurableSettingsWithMultipleLanguages() {
        let info = LegacyFixtures.sourceInfo(languages: ["en", "ja"])
        let source = LegacyFixtures.source(info: info, runner: FakeLegacyRunner(features: .none()))
        XCTAssertTrue(source.hasConfigurableSettings)
    }

    // MARK: - getSettings routing

    func testGetSettingsReturnsStaticWhenDynamicDisabled() {
        let source = LegacyFixtures.source(runner: FakeLegacyRunner(features: .none()))
        let expectation = expectation(description: "settings")
        source.getSettings { result in
            if case .success(let settings) = result {
                XCTAssertTrue(settings.isEmpty)
            } else {
                XCTFail("expected success")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testGetSettingsMergesDynamicSettings() throws {
        var features = AidokuRunnerLegacySourceFeatures.none()
        features.dynamicSettings = true
        let runner = FakeLegacyRunner(features: features)
        let dynamicSetting = try JSONDecoder().decode(
            AidokuRunnerLegacySettingItem.self,
            from: Data(#"{"type":"switch","key":"dynamic"}"#.utf8)
        )
        runner.settingsResult = .success([dynamicSetting])
        let source = LegacyFixtures.source(runner: runner)

        let expectation = expectation(description: "settings")
        source.getSettings { result in
            switch result {
                case .success(let settings):
                    // staticSettings (none here) + dynamic
                    XCTAssertEqual(settings.count, 1)
                    XCTAssertEqual(settings.first?.key, "dynamic")
                    XCTAssertEqual(runner.getSettingsCallCount, 1)
                case .failure:
                    XCTFail("expected success")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    // MARK: - Unavailable backend

    func testUnavailableRunnerFailsSearchButAllowsEmptySettings() {
        let runner = AidokuRunnerLegacyUnavailableRunner()

        let searchExpectation = expectation(description: "search")
        runner.getSearchMangaList(query: "x", page: 1, filters: []) { result in
            if case .failure(let error) = result {
                XCTAssertEqual(error as? AidokuRunnerLegacyError, .backendUnavailable)
            } else {
                XCTFail("expected failure")
            }
            searchExpectation.fulfill()
        }

        let settingsExpectation = expectation(description: "settings")
        runner.getSettings { result in
            if case .success(let settings) = result {
                XCTAssertTrue(settings.isEmpty)
            } else {
                XCTFail("expected success")
            }
            settingsExpectation.fulfill()
        }

        let coversExpectation = expectation(description: "covers")
        runner.getAlternateCovers(manga: LegacyFixtures.manga()) { result in
            if case .success(let covers) = result {
                XCTAssertTrue(covers.isEmpty)
            } else {
                XCTFail("expected success")
            }
            coversExpectation.fulfill()
        }

        wait(for: [searchExpectation, settingsExpectation, coversExpectation], timeout: 1)
    }

    func testUnavailableBackendFactoryProducesUnavailableRunner() throws {
        let factory = UnavailableAidokuRunnerLegacyBackendFactory()
        let runner = try factory.makeRunner(sourceURL: FileManager.default.temporaryDirectory, info: LegacyFixtures.sourceInfo())
        XCTAssertFalse(runner.features.providesListings)
    }
}
