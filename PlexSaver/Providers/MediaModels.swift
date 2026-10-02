//
//  MediaModels.swift
//  PlexSaver
//

import Foundation

/// Provider-agnostic media library
struct MediaLibrary: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let type: String  // "movies", "tvshows", "music"
}

/// Provider-agnostic media item with artwork paths
struct MediaItem: Codable, Sendable {
    let id: String
    let title: String
    let year: Int?
    let artPaths: [ImageSourceType: String]
    /// Originating library id, tagged by `ImagePool.loadMediaItems` so the disk
    /// cache can retain metadata and honor the currently selected libraries.
    /// Defaults to nil for callers that
    /// don't know it (the provider converters).
    var libraryId: String? = nil
    /// Provider content kind keeps movies, series, albums, and artists with the
    /// same title separate. IDs are not used: duplicate editions share a title.
    var mediaType: String? = nil
    /// Optional fields keep catalogues saved before metadata filtering readable.
    var genres: [String]? = nil
    var collections: [String]? = nil
    var isFavorite: Bool? = nil
    var isWatched: Bool? = nil

    /// Returns the art path for the given source type, or a random available
    /// path for `.mixed` (Backgrounds and Posters). The optional flag exists
    /// only for compatibility with legacy saved settings.
    func artPath(for source: ImageSourceType, includePostersInMixed: Bool = true) -> String? {
        switch source {
        case .mixed:
            if includePostersInMixed {
                return artPaths.values.randomElement()
            }
            return artPaths[.fanart]
        default:
            return artPaths[source]
        }
    }

    /// Identity key for title-level uniqueness (U5). Two entries that resolve to
    /// the same `(title, year)` — e.g. the same movie in a Movies and a 4K
    /// library, or the same movie shown as poster and fanart in `.mixed` — share
    /// this key so the registry treats them as one item and never displays both
    /// at once. Case-folded so trivial casing differences don't defeat it.
    var titleKey: String {
        // Photos with the same camera-generated file name in different folders
        // remain distinct artwork, unlike duplicate editions of a movie.
        if mediaType == "photo" { return "photo|\(id)" }
        let identity = "\(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(year.map(String.init) ?? "")"
        guard let mediaType, !mediaType.isEmpty else { return identity }
        return "\(mediaType.lowercased())|\(identity)"
    }
}

/// The type of media provider
enum ProviderType: String, Codable, CaseIterable, Sendable {
    case plex
    case jellyfin
    case local

    var filterCapabilities: MediaFilterCapabilities {
        switch self {
        case .plex: return MediaFilterCapabilities(supportsGenres: true, supportsCollections: true, supportsUnwatched: true)
        case .jellyfin: return MediaFilterCapabilities(supportsGenres: true, supportsFavorites: true, supportsUnwatched: true)
        case .local: return MediaFilterCapabilities()
        }
    }

    var displayName: String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        case .local: return "Local Folder"
        }
    }
}
