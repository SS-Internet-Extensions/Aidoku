//
//  LegacyDeepLinkHandler.swift
//  AidokuLegacy
//
//  Pure-Foundation deep-link / URL import parser (iOS 12 safe).
//
//  Turns an inbound URL (custom "aidoku://" scheme, an http(s) link, or a
//  local file) into a single `LegacyDeepLinkAction` that the AppDelegate can
//  switch on and route to the existing install / backup / tracker flows.
//
//  No UIKit, no async/await, no Combine, no singletons. Everything is a static
//  function so the parser stays deterministic and unit-test friendly.
//

import Foundation

/// The result of parsing an inbound URL. Every inbound URL maps to exactly one
/// case; there is no `nil` / failure result, unrecognised input falls through
/// to `.unsupported`.
enum LegacyDeepLinkAction: Equatable {
    /// A source repository / source-list URL to add (e.g. an `index.min.json`).
    case addSourceList(URL)
    /// A `.aib` / `.json` backup file, or a remote backup URL, to import.
    case importBackup(URL)
    /// A `.aix` source package to install.
    case installPackage(URL)
    /// A request to open a specific manga in a specific source.
    case openManga(sourceKey: String, mangaKey: String)
    /// An OAuth redirect: AniList implicit grant (`#access_token=`) carries the
    /// token, MyAnimeList authorization-code grant (`?code=`) carries the code.
    case trackerCallback(token: String?, code: String?)
    /// A self-hosted server base URL (komga / kavita).
    case addSelfHostedServer(URL)
    /// Anything we could not classify.
    case unsupported(URL)
}

/// Caseless namespace for the deep-link parser. Call `action(for:)` with the
/// inbound URL and switch on the returned `LegacyDeepLinkAction`.
enum LegacyDeepLinkHandler {

    // MARK: - Entry point

    /// Classify an inbound URL into a single `LegacyDeepLinkAction`.
    ///
    /// Dispatch order: local files first (they have no useful scheme to match),
    /// then the custom "aidoku" scheme, then plain http/https links. Anything
    /// that matches nothing returns `.unsupported(url)`.
    static func action(for url: URL) -> LegacyDeepLinkAction {
        // Local file imports (Files app, AirDrop, "Open in...", etc.).
        if url.isFileURL {
            return fileAction(for: url)
        }

        let scheme = url.scheme?.lowercased() ?? ""

        // Custom app scheme: aidoku://...
        if scheme == "aidoku" {
            return aidokuSchemeAction(for: url)
        }

        // Universal / web links.
        if scheme == "http" || scheme == "https" {
            return webAction(for: url)
        }

        // Unknown scheme.
        return .unsupported(url)
    }

    // MARK: - Local files

    /// Classify a `file://` URL purely by its path extension.
    private static func fileAction(for url: URL) -> LegacyDeepLinkAction {
        switch url.pathExtension.lowercased() {
        case "aib", "json":
            // Aidoku backup (binary `.aib`) or legacy JSON backup.
            return .importBackup(url)
        case "aix":
            // Aidoku source package.
            return .installPackage(url)
        default:
            return .unsupported(url)
        }
    }

    // MARK: - aidoku:// scheme

    /// Classify a custom-scheme URL (`aidoku://<host>/<path>?<query>`).
    private static func aidokuSchemeAction(for url: URL) -> LegacyDeepLinkAction {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()

        // Add a source list / source repository.
        // e.g. aidoku://addSourceList?url=https://example.com/index.min.json
        if host == "addsourcelist" || host == "add-source-list"
            || path.contains("source-list") || path.contains("sourcelist") {
            if let embedded = embeddedURL(from: components) {
                return .addSourceList(embedded)
            }
            return .unsupported(url)
        }

        // Import a backup from a remote URL.
        // e.g. aidoku://addBackup?url=https://example.com/backup.aib
        if host == "addbackup" || host == "backup" {
            if let embedded = embeddedURL(from: components) {
                return .importBackup(embedded)
            }
            return .unsupported(url)
        }

        // Install a single source package.
        // e.g. aidoku://addSource?url=https://example.com/source.aix
        if host == "addsource" || host == "install" {
            if let embedded = embeddedURL(from: components),
               embedded.pathExtension.lowercased() == "aix" {
                return .installPackage(embedded)
            }
            return .unsupported(url)
        }

        // Open a specific manga.
        // e.g. aidoku://manga?sourceKey=abc&mangaKey=123
        if host == "manga" {
            if let sourceKey = queryValue(in: components, names: ["sourceKey", "source"]),
               let mangaKey = queryValue(in: components, names: ["mangaKey", "manga", "id"]) {
                return .openManga(sourceKey: sourceKey, mangaKey: mangaKey)
            }
            return .unsupported(url)
        }

        // OAuth / tracker callback.
        // e.g. aidoku://tracker#access_token=... or aidoku://oauth?code=...
        if host == "tracker" || host == "oauth" || host == "auth" || path.contains("oauth") {
            let token = fragmentValue(in: url, name: "access_token")
            let code = queryValue(in: components, names: ["code"])
            return .trackerCallback(token: token, code: code)
        }

        // Add a self-hosted server (komga / kavita).
        // e.g. aidoku://addServer?url=https://komga.example.com
        if host == "addserver" || host == "komga" || host == "kavita" {
            if let embedded = embeddedURL(from: components) {
                return .addSelfHostedServer(embedded)
            }
            return .unsupported(url)
        }

        return .unsupported(url)
    }

    // MARK: - http(s) links

    /// Classify a plain web link. Used both for universal links and for OAuth
    /// redirect URIs that round-trip through a normal https host.
    private static func webAction(for url: URL) -> LegacyDeepLinkAction {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = url.host?.lowercased() ?? ""
        let fragment = url.fragment ?? ""
        let query = url.query ?? ""

        // AniList implicit grant: the access token rides in the fragment.
        if fragment.contains("access_token=") {
            let token = fragmentValue(in: url, name: "access_token")
            return .trackerCallback(token: token, code: nil)
        }

        // MyAnimeList authorization-code grant: `?code=` on the MAL host.
        if query.contains("code=") && host.contains("myanimelist") {
            let code = queryValue(in: components, names: ["code"])
            return .trackerCallback(token: nil, code: code)
        }

        // Direct package / backup links by extension.
        switch url.pathExtension.lowercased() {
        case "aix":
            return .installPackage(url)
        case "aib", "json":
            return .importBackup(url)
        default:
            break
        }

        // Source-list heuristics: a hosted index, a `/sources` path, or a link
        // that itself embeds a `url=` query item pointing at a source list.
        let path = url.path.lowercased()
        if path.hasSuffix("index.min.json")
            || path.contains("/sources")
            || embeddedURL(from: components) != nil {
            return .addSourceList(url)
        }

        return .unsupported(url)
    }

    // MARK: - Helpers

    /// Read the `url` query item (percent-decoded) and return it as a `URL`.
    /// URLComponents already percent-decodes `queryItems[].value`, so the raw
    /// value is fed straight into `URL(string:)`.
    private static func embeddedURL(from components: URLComponents?) -> URL? {
        guard let value = queryValue(in: components, names: ["url"]) else {
            return nil
        }
        return URL(string: value)
    }

    /// Return the value of the first matching query item, comparing names
    /// case-insensitively. Empty values are treated as absent.
    private static func queryValue(in components: URLComponents?, names: [String]) -> String? {
        guard let items = components?.queryItems else {
            return nil
        }
        let wanted = names.map { $0.lowercased() }
        for item in items where wanted.contains(item.name.lowercased()) {
            if let value = item.value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Pull a single value out of the URL fragment, which OAuth implicit-grant
    /// redirects format like a query string: `a=1&access_token=xyz&b=2`.
    /// Splits on `&`, then on the first `=`, and percent-decodes the value.
    private static func fragmentValue(in url: URL, name: String) -> String? {
        guard let fragment = url.fragment, !fragment.isEmpty else {
            return nil
        }
        for pair in fragment.components(separatedBy: "&") {
            guard let separator = pair.range(of: "=") else {
                continue
            }
            let key = String(pair[pair.startIndex..<separator.lowerBound])
            if key == name {
                let rawValue = String(pair[separator.upperBound...])
                if rawValue.isEmpty {
                    return nil
                }
                return rawValue.removingPercentEncoding ?? rawValue
            }
        }
        return nil
    }
}
