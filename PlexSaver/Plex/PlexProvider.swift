//
//  PlexProvider.swift
//  PlexSaver
//

import AppKit

/// MediaProvider implementation for Plex servers
actor PlexProvider: MediaProvider {
    private let client: PlexClient

    nonisolated let serverName: String = "Plex Server"

    init(serverURL: String, token: String) {
        self.client = PlexClient(serverURL: serverURL, token: token)
    }

    func fetchLibraries() async throws -> [MediaLibrary] {
        let plexLibraries = try await client.fetchLibraries()
        return plexLibraries.map { $0.toMediaLibrary() }
    }

    func fetchItems(libraryId: String) async throws -> [MediaItem] {
        let plexItems = try await client.fetchAllItems(sectionId: libraryId)
        return plexItems.map { $0.toMediaItem() }
    }

    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        return try await client.fetchImage(imagePath: path, width: width, height: height)
    }

    func testConnection() async throws -> Bool {
        return try await client.testConnection()
    }
}
