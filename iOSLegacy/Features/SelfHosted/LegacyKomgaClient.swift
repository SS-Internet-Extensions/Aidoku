//
//  LegacyKomgaClient.swift
//  AidokuLegacy
//
//  REST client for self-hosted Komga / Kavita servers using URLSession completion
//  handlers (iOS 12 safe; no async/await, no Combine). Komga is fully supported via
//  HTTP Basic auth. Kavita is best-effort: it authenticates via POST /api/Account/login
//  to obtain a JWT, caches it, and uses Bearer auth for subsequent requests.
//
//  All response parsing is defensive: any structural mismatch yields
//  LegacyKomgaError.invalidResponse, and HTTP 401 yields LegacyKomgaError.unauthorized.
//

import Foundation

final class LegacyKomgaClient {
    private let server: LegacyKomgaServer
    private let session: URLSession

    // Cached Kavita bearer token (JWT). Komga does not use this.
    private var kavitaToken: String?

    init(server: LegacyKomgaServer, session: URLSession = .shared) {
        self.server = server
        self.session = session
    }

    // MARK: - Public API

    // Lists series matching an optional query. `page` is 0-indexed (Komga's Spring
    // pagination convention); results are limited to 20 entries per page.
    func listSeries(
        query: String?,
        page: Int,
        completion: @escaping (Result<[LegacyKomgaSeries], Error>) -> Void
    ) {
        switch server.kind {
            case .komga:
                listKomgaSeries(query: query, page: page, completion: completion)
            case .kavita:
                listKavitaSeries(query: query, page: page, completion: completion)
        }
    }

    // Lists the books inside a series, sorted ascending by number.
    func listBooks(
        seriesId: String,
        completion: @escaping (Result<[LegacyKomgaBook], Error>) -> Void
    ) {
        switch server.kind {
            case .komga:
                listKomgaBooks(seriesId: seriesId, completion: completion)
            case .kavita:
                completion(.failure(LegacyKomgaError.requestFailed("Kavita not yet supported")))
        }
    }

    // URL for a single page image. `page` is 1-indexed (both Komga and Kavita).
    func pageImageURL(bookId: String, page: Int) -> URL? {
        guard let base = server.url else { return nil }
        switch server.kind {
            case .komga:
                return base.appendingPathComponent("api/v1/books/\(bookId)/pages/\(page)")
            case .kavita:
                return nil
        }
    }

    // URL for a series cover thumbnail.
    func coverImageURL(seriesId: String) -> URL? {
        guard let base = server.url else { return nil }
        switch server.kind {
            case .komga:
                return base.appendingPathComponent("api/v1/series/\(seriesId)/thumbnail")
            case .kavita:
                return nil
        }
    }

    // MARK: - Komga implementation

    private func listKomgaSeries(
        query: String?,
        page: Int,
        completion: @escaping (Result<[LegacyKomgaSeries], Error>) -> Void
    ) {
        guard let base = server.url else {
            completion(.failure(LegacyKomgaError.notConfigured))
            return
        }
        guard var components = URLComponents(
            url: base.appendingPathComponent("api/v1/series"),
            resolvingAgainstBaseURL: false
        ) else {
            completion(.failure(LegacyKomgaError.notConfigured))
            return
        }
        var items = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "size", value: "20")
        ]
        if let query = query, !query.isEmpty {
            items.append(URLQueryItem(name: "search", value: query))
        }
        components.queryItems = items
        guard let url = components.url else {
            completion(.failure(LegacyKomgaError.notConfigured))
            return
        }

        performJSON(request: basicAuthRequest(url: url)) { result in
            switch result {
                case .success(let json):
                    // Komga returns a Spring page object: { content: [ ... ] }.
                    guard let content = json["content"] as? [[String: Any]] else {
                        completion(.failure(LegacyKomgaError.invalidResponse))
                        return
                    }
                    let series: [LegacyKomgaSeries] = content.compactMap { item in
                        guard let id = LegacyKomgaClient.stringId(item["id"]) else { return nil }
                        let metadata = item["metadata"] as? [String: Any]
                        let title = (metadata?["title"] as? String)
                            ?? (item["name"] as? String)
                            ?? "Unknown"
                        let booksCount = (item["booksCount"] as? Int)
                            ?? (item["booksCount"] as? NSNumber)?.intValue
                            ?? 0
                        var cover: URL?
                        if let coverBase = self.server.url {
                            cover = coverBase.appendingPathComponent("api/v1/series/\(id)/thumbnail")
                        }
                        return LegacyKomgaSeries(
                            id: id,
                            title: title,
                            booksCount: booksCount,
                            coverURL: cover
                        )
                    }
                    completion(.success(series))
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    private func listKomgaBooks(
        seriesId: String,
        completion: @escaping (Result<[LegacyKomgaBook], Error>) -> Void
    ) {
        guard let base = server.url else {
            completion(.failure(LegacyKomgaError.notConfigured))
            return
        }
        guard var components = URLComponents(
            url: base.appendingPathComponent("api/v1/series/\(seriesId)/books"),
            resolvingAgainstBaseURL: false
        ) else {
            completion(.failure(LegacyKomgaError.notConfigured))
            return
        }
        components.queryItems = [URLQueryItem(name: "size", value: "1000")]
        guard let url = components.url else {
            completion(.failure(LegacyKomgaError.notConfigured))
            return
        }

        performJSON(request: basicAuthRequest(url: url)) { result in
            switch result {
                case .success(let json):
                    guard let content = json["content"] as? [[String: Any]] else {
                        completion(.failure(LegacyKomgaError.invalidResponse))
                        return
                    }
                    let books: [LegacyKomgaBook] = content.compactMap { item in
                        guard let id = LegacyKomgaClient.stringId(item["id"]) else { return nil }
                        let metadata = item["metadata"] as? [String: Any]
                        let title = (metadata?["title"] as? String)
                            ?? (item["name"] as? String)
                            ?? "Unknown"
                        // Komga exposes the chapter number as a string in metadata.number.
                        let numberString = (metadata?["number"] as? String)
                        let number = numberString.flatMap { Float($0) }
                            ?? Float(item["number"] as? Int ?? 0)
                        let media = item["media"] as? [String: Any]
                        let pageCount = (media?["pagesCount"] as? Int)
                            ?? (media?["pagesCount"] as? NSNumber)?.intValue
                            ?? 0
                        return LegacyKomgaBook(
                            id: id,
                            title: title,
                            number: number,
                            pageCount: pageCount
                        )
                    }
                    .sorted { $0.number < $1.number }
                    completion(.success(books))
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    // MARK: - Kavita implementation (best-effort)

    private func listKavitaSeries(
        query: String?,
        page: Int,
        completion: @escaping (Result<[LegacyKomgaSeries], Error>) -> Void
    ) {
        authenticateKavita { [weak self] result in
            guard let self = self else { return }
            switch result {
                case .success(let token):
                    guard let base = self.server.url else {
                        completion(.failure(LegacyKomgaError.notConfigured))
                        return
                    }
                    let url = base.appendingPathComponent("api/Series")
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                    // Kavita's /api/Series returns a bare array of series objects.
                    self.performData(request: request) { dataResult in
                        switch dataResult {
                            case .success(let data):
                                guard
                                    let array = (try? JSONSerialization.jsonObject(with: data, options: []))
                                        as? [[String: Any]]
                                else {
                                    completion(.failure(LegacyKomgaError.invalidResponse))
                                    return
                                }
                                let series: [LegacyKomgaSeries] = array.compactMap { item in
                                    guard let id = LegacyKomgaClient.stringId(item["id"]) else { return nil }
                                    let title = (item["name"] as? String)
                                        ?? (item["originalName"] as? String)
                                        ?? "Unknown"
                                    let pages = (item["pages"] as? Int) ?? 0
                                    return LegacyKomgaSeries(
                                        id: id,
                                        title: title,
                                        booksCount: pages,
                                        coverURL: nil
                                    )
                                }
                                completion(.success(series))
                            case .failure(let error):
                                completion(.failure(error))
                        }
                    }
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    // Logs in to Kavita and caches the returned JWT token.
    private func authenticateKavita(completion: @escaping (Result<String, Error>) -> Void) {
        if let token = kavitaToken, !token.isEmpty {
            completion(.success(token))
            return
        }
        guard let base = server.url else {
            completion(.failure(LegacyKomgaError.notConfigured))
            return
        }
        let url = base.appendingPathComponent("api/Account/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "username": server.username,
            "password": server.password
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            completion(.failure(error))
            return
        }

        performJSON(request: request) { [weak self] result in
            switch result {
                case .success(let json):
                    guard let token = json["token"] as? String, !token.isEmpty else {
                        completion(.failure(LegacyKomgaError.invalidResponse))
                        return
                    }
                    self?.kavitaToken = token
                    completion(.success(token))
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    // MARK: - Networking

    // Builds a GET request carrying an HTTP Basic auth header from username:password.
    private func basicAuthRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let raw = "\(server.username):\(server.password)"
        if let encoded = raw.data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // Executes a request and decodes a top-level JSON object.
    private func performJSON(
        request: URLRequest,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        performData(request: request) { result in
            switch result {
                case .success(let data):
                    guard
                        let json = (try? JSONSerialization.jsonObject(with: data, options: []))
                            as? [String: Any]
                    else {
                        completion(.failure(LegacyKomgaError.invalidResponse))
                        return
                    }
                    completion(.success(json))
                case .failure(let error):
                    completion(.failure(error))
            }
        }
    }

    // Executes a request and returns the raw response body, mapping transport and
    // HTTP-status failures to LegacyKomgaError values.
    private func performData(
        request: URLRequest,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    completion(.failure(LegacyKomgaError.unauthorized))
                    return
                }
                if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
                    completion(.failure(LegacyKomgaError.requestFailed(
                        "Server returned status \(httpResponse.statusCode)."
                    )))
                    return
                }
            }
            guard let data = data else {
                completion(.failure(LegacyKomgaError.invalidResponse))
                return
            }
            completion(.success(data))
        }
        task.resume()
    }

    // MARK: - Helpers

    // Normalizes an id field that may arrive as a String or a number.
    private static func stringId(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let int = value as? Int {
            return String(int)
        }
        return nil
    }
}
