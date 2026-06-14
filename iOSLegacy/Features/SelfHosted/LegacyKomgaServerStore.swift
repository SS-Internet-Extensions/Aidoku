//
//  LegacyKomgaServerStore.swift
//  AidokuLegacy
//
//  UserDefaults-backed persistence for self-hosted (Komga / Kavita) server records.
//  Mirrors the LegacyTrackerStore / LegacyLocalFileStore patterns: a single shared
//  instance, JSONEncoder/Decoder round-tripping, and a change notification posted
//  on every mutation so observers can reload.
//

import Foundation

final class LegacyKomgaServerStore {
    static let shared = LegacyKomgaServerStore()

    private let serversKey = "AidokuLegacy.selfhosted.servers"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // All persisted server records.
    var servers: [LegacyKomgaServer] {
        guard
            let data = UserDefaults.standard.data(forKey: serversKey),
            let servers = try? decoder.decode([LegacyKomgaServer].self, from: data)
        else {
            return []
        }
        return servers
    }

    // Returns the server with the given id, if any.
    func server(id: String) -> LegacyKomgaServer? {
        return servers.first { $0.id == id }
    }

    // Appends a new server record.
    func add(_ server: LegacyKomgaServer) {
        var current = servers
        current.append(server)
        persist(current)
    }

    // Replaces an existing record matching the same id (no-op if absent).
    func update(_ server: LegacyKomgaServer) {
        var current = servers
        guard let index = current.firstIndex(where: { $0.id == server.id }) else {
            return
        }
        current[index] = server
        persist(current)
    }

    // Removes the record with the given id.
    func remove(id: String) {
        persist(servers.filter { $0.id != id })
    }

    // MARK: - Persistence

    private func persist(_ servers: [LegacyKomgaServer]) {
        if let data = try? encoder.encode(servers) {
            UserDefaults.standard.set(data, forKey: serversKey)
            NotificationCenter.default.post(name: .aidokuLegacySelfHostedServersDidChange, object: nil)
        }
    }
}

// Notification posted whenever the stored self-hosted server list changes.
extension Notification.Name {
    static let aidokuLegacySelfHostedServersDidChange =
        Notification.Name("AidokuLegacySelfHostedServersDidChange")
}
