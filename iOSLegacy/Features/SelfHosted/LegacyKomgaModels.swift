//
//  LegacyKomgaModels.swift
//  AidokuLegacy
//
//  Models for self-hosted Komga / Kavita manga servers. iOS 12 / Foundation only.
//  The server records are Codable for UserDefaults persistence; the series/book
//  value types are lightweight DTOs decoded from REST responses.
//

import Foundation

// Identifies the kind of self-hosted server a record points at.
enum LegacyKomgaServerKind: String, Codable {
    case komga
    case kavita

    // Human-readable name shown in the UI.
    var displayName: String {
        switch self {
            case .komga:
                return "Komga"
            case .kavita:
                return "Kavita"
        }
    }
}

// A configured self-hosted server with HTTP Basic credentials.
struct LegacyKomgaServer: Codable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var username: String
    var password: String
    var kind: LegacyKomgaServerKind

    init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String,
        username: String,
        password: String,
        kind: LegacyKomgaServerKind
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.kind = kind
    }

    // Parsed base URL with any trailing slash trimmed; nil when malformed.
    var url: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var value = trimmed
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return URL(string: value)
    }
}

// A series (manga) listed by a server.
struct LegacyKomgaSeries {
    var id: String
    var title: String
    var booksCount: Int
    var coverURL: URL?

    init(id: String, title: String, booksCount: Int = 0, coverURL: URL? = nil) {
        self.id = id
        self.title = title
        self.booksCount = booksCount
        self.coverURL = coverURL
    }
}

// A single book (chapter/volume) inside a series.
struct LegacyKomgaBook {
    var id: String
    var title: String
    var number: Float
    var pageCount: Int

    init(id: String, title: String, number: Float = 0, pageCount: Int = 0) {
        self.id = id
        self.title = title
        self.number = number
        self.pageCount = pageCount
    }
}

// Errors surfaced by self-hosted server network operations.
enum LegacyKomgaError: Error, LocalizedError {
    case notConfigured
    case invalidResponse
    case requestFailed(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
            case .notConfigured:
                return "The server is not configured correctly."
            case .invalidResponse:
                return "Received an invalid response from the server."
            case .requestFailed(let message):
                return message
            case .unauthorized:
                return "Authentication failed. Check the username and password."
        }
    }
}
