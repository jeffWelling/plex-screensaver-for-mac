//
//  MediaProvider.swift
//  PlexSaver
//

import AppKit

/// Protocol for media server providers (Plex, Jellyfin, etc.)
protocol MediaProvider: Actor {
    /// Human-readable server name for display
    var serverName: String { get }

    /// Fetch available media libraries
    func fetchLibraries() async throws -> [MediaLibrary]

    /// Fetch all media items in a library
    func fetchItems(libraryId: String) async throws -> [MediaItem]

    /// Fetch an image at the given path, scaled to the given dimensions
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage

    /// Test connectivity to the server
    func testConnection() async throws -> Bool
}
