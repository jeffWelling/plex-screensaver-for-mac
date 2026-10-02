//
//  MediaProvider.swift
//  PlexSaver
//

import AppKit

/// Protocol for media server providers (Plex, Jellyfin, etc.)
protocol MediaProvider: Sendable {
    /// Human-readable server name for display
    var serverName: String { get }

    var filterCapabilities: MediaFilterCapabilities { get }

    /// Discover choices only in the selected libraries.
    func fetchFilterOptions(libraryIds: [String]) async throws -> MediaFilterOptions

    /// Fetch available media libraries
    func fetchLibraries() async throws -> [MediaLibrary]

    /// Fetch all media items in a library
    func fetchItems(libraryId: String) async throws -> [MediaItem]

    /// Fetch an image at the given path, scaled to the given dimensions
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage
}

extension MediaProvider {
    var filterCapabilities: MediaFilterCapabilities { MediaFilterCapabilities() }

    func fetchFilterOptions(libraryIds: [String]) async throws -> MediaFilterOptions {
        guard filterCapabilities.hasFilters else { return MediaFilterOptions() }
        var items: [MediaItem] = []
        for id in Set(libraryIds).sorted() {
            try Task.checkCancellation()
            items.append(contentsOf: try await fetchItems(libraryId: id))
        }
        try Task.checkCancellation()
        let options = MediaFilterOptions(items: items)
        return MediaFilterOptions(genres: filterCapabilities.supportsGenres ? options.genres : [],
                                  collections: filterCapabilities.supportsCollections ? options.collections : [])
    }
}
