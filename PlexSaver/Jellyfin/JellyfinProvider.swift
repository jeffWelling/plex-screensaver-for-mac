//
//  JellyfinProvider.swift
//  PlexSaver
//

import AppKit

/// MediaProvider implementation for Jellyfin servers
actor JellyfinProvider: MediaProvider {
    private let client: JellyfinClient
    private let jellyfinServerURL: String

    nonisolated let serverName: String = "Jellyfin Server"

    init(serverURL: String, accessToken: String, userId: String) {
        self.jellyfinServerURL = serverURL
        self.client = JellyfinClient(serverURL: serverURL, accessToken: accessToken, userId: userId)
    }

    func fetchLibraries() async throws -> [MediaLibrary] {
        let jfLibraries = try await client.fetchLibraries()
        return jfLibraries.map { $0.toMediaLibrary() }
    }

    func fetchItems(libraryId: String) async throws -> [MediaItem] {
        let jfItems = try await client.fetchAllItems(libraryId: libraryId)
        return jfItems.map { $0.toMediaItem() }
    }

    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        return try await client.fetchImage(path: path, width: width, height: height)
    }

    func testConnection() async throws -> Bool {
        return try await client.testConnection()
    }
}
