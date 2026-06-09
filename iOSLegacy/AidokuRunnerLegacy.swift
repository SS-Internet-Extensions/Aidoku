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
    let staticFilters: [AidokuRunnerLegacyFilter]
    let staticSettings: [AidokuRunnerLegacySettingItem]
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
        self.staticFilters = Self.filters(in: url)
        let sourceSettings = Self.settings(in: url)
        self.staticSettings = sourceSettings
        self.imageUrl = Self.iconURL(in: url)

        var baseUrls = [URL]()
        if let urlString = sourceInfo.url, let url = URL(string: urlString) {
            baseUrls.append(url)
        }
        if let sourceUrls = sourceInfo.urls {
            baseUrls.append(contentsOf: sourceUrls.compactMap { URL(string: $0) })
        }
        self.urls = baseUrls
        Self.registerDefaults(
            sourceKey: sourceInfo.id,
            languages: sourceInfo.languages,
            urls: baseUrls,
            config: info.config,
            settings: sourceSettings
        )
        self.runner = runner
    }

    convenience init(
        installedSourceURL: URL,
        backendFactory: AidokuRunnerLegacyBackendFactory = AidokuRunnerLegacyWasmBackendFactory()
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

    var hasConfigurableSettings: Bool {
        return !staticSettings.isEmpty
            || runner.features.dynamicSettings
            || languages.count > 1
            || ((config?.allowsBaseUrlSelect ?? false) && urls.count > 1)
    }

    func getSettings(completion: @escaping (Result<[AidokuRunnerLegacySettingItem], Error>) -> Void) {
        guard runner.features.dynamicSettings else {
            completion(.success(staticSettings))
            return
        }
        runner.getSettings { [weak self] result in
            guard let self = self else { return }
            switch result {
                case .success(let dynamicSettings):
                    let allSettings = self.staticSettings + dynamicSettings
                    Self.registerDefaults(
                        sourceKey: self.key,
                        languages: self.languages,
                        urls: self.urls,
                        config: self.config,
                        settings: allSettings
                    )
                    completion(.success(allSettings))
                case .failure(let error):
                    completion(.failure(error))
            }
        }
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

    private static func filters(in sourceURL: URL) -> [AidokuRunnerLegacyFilter] {
        let filtersURL = sourceURL.appendingPathComponent("filters.json")
        guard
            FileManager.default.fileExists(atPath: filtersURL.path),
            let data = try? Data(contentsOf: filtersURL),
            let filters = try? JSONDecoder().decode([AidokuRunnerLegacyFilter].self, from: data)
        else {
            return []
        }
        return filters
    }

    private static func settings(in sourceURL: URL) -> [AidokuRunnerLegacySettingItem] {
        let settingsURL = sourceURL.appendingPathComponent("settings.json")
        guard
            FileManager.default.fileExists(atPath: settingsURL.path),
            let data = try? Data(contentsOf: settingsURL),
            let settings = try? JSONDecoder().decode([AidokuRunnerLegacySettingItem].self, from: data)
        else {
            return []
        }
        return settings
    }

    private static func registerDefaults(
        sourceKey: String,
        languages: [String],
        urls: [URL],
        config: AidokuRunnerLegacySourceInfo.Configuration?,
        settings: [AidokuRunnerLegacySettingItem]
    ) {
        var defaults: [String: Any] = [:]

        let languageDefaults = defaultLanguages(from: languages)
        if let firstLanguage = languageDefaults.first {
            defaults["\(sourceKey).language"] = firstLanguage
            defaults["\(sourceKey).languages"] = languageDefaults
        }

        if config?.allowsBaseUrlSelect ?? false, urls.count > 1, let defaultURL = urls.first?.absoluteString {
            defaults["\(sourceKey).url"] = defaultURL
        }

        collectSettingDefaults(settings, sourceKey: sourceKey, defaults: &defaults)

        if !defaults.isEmpty {
            UserDefaults.standard.register(defaults: defaults)
        }
    }

    private static func defaultLanguages(from languages: [String]) -> [String] {
        guard !languages.isEmpty else { return [] }

        var preferredValues: [String] = []
        for identifier in Locale.preferredLanguages {
            let normalizedIdentifier = identifier.replacingOccurrences(of: "_", with: "-")
            appendUnique(normalizedIdentifier, to: &preferredValues)

            let locale = Locale(identifier: identifier)
            guard let languageCode = locale.languageCode else { continue }

            if let scriptCode = locale.scriptCode {
                appendUnique("\(languageCode)-\(scriptCode)", to: &preferredValues)
            }
            if let regionCode = locale.regionCode {
                appendUnique("\(languageCode)-\(regionCode)", to: &preferredValues)
            }
            appendUnique(languageCode, to: &preferredValues)
        }

        var languagesByNormalizedValue: [String: String] = [:]
        for language in languages {
            let normalizedLanguage = language.lowercased()
            if languagesByNormalizedValue[normalizedLanguage] == nil {
                languagesByNormalizedValue[normalizedLanguage] = language
            }
        }

        var result: [String] = []
        for preferredValue in preferredValues {
            guard let language = languagesByNormalizedValue[preferredValue.lowercased()] else { continue }
            appendUnique(language, to: &result)
        }

        if result.isEmpty, let fallback = languages.first {
            result = [fallback]
        }
        return result
    }

    private static func collectSettingDefaults(
        _ settings: [AidokuRunnerLegacySettingItem],
        sourceKey: String,
        defaults: inout [String: Any]
    ) {
        for setting in settings {
            switch setting.type {
                case "group", "page":
                    collectSettingDefaults(setting.items ?? [], sourceKey: sourceKey, defaults: &defaults)
                case "select", "segment":
                    if let key = setting.key {
                        if let value = setting.defaultValue?.userDefaultsValue {
                            defaults["\(sourceKey).\(key)"] = defaultValue(value, sourceKey: sourceKey, settingKey: key)
                        } else if let value = setting.values?.first {
                            defaults["\(sourceKey).\(key)"] = value
                        }
                    }
                case "switch", "toggle", "text", "multi-select", "multi-single-select", "stepper", "editable-list":
                    if let key = setting.key, let value = setting.defaultValue?.userDefaultsValue {
                        defaults["\(sourceKey).\(key)"] = defaultValue(value, sourceKey: sourceKey, settingKey: key)
                    }
                default:
                    continue
            }
        }
    }

    private static func defaultValue(_ value: Any, sourceKey: String, settingKey: String) -> Any {
        if sourceKey.lowercased().contains("mangadex"), settingKey == "lockedChapters" {
            return false
        }
        return value
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        guard !value.isEmpty, !values.contains(value) else { return }
        values.append(value)
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
