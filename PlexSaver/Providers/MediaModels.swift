//
//  MediaModels.swift
//  PlexSaver
//

import Foundation

/// Provider-agnostic media library
struct MediaLibrary: Identifiable {
    let id: String
    let name: String
    let type: String  // "movies", "tvshows", "music"
}

/// Provider-agnostic media item with artwork paths
struct MediaItem {
    let id: String
    let title: String
    let year: Int?
    let artPaths: [ImageSourceType: String]
    /// Originating library id, tagged by `ImagePool.loadMediaItems` so the disk
    /// cache can record which library each image came from and Phase 1 can filter
    /// to the currently-selected libraries (N3). Defaults to nil for callers that
    /// don't know it (the provider converters).
    var libraryId: String? = nil

    /// Returns the art path for the given source type, or a random available path for .mixed
    func artPath(for source: ImageSourceType) -> String? {
        switch source {
        case .mixed:
            return artPaths.values.randomElement()
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
        "\(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(year.map(String.init) ?? "")"
    }
}

/// The type of media provider
enum ProviderType: String, Codable, CaseIterable {
    case plex
    case jellyfin

    var displayName: String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin"
        }
    }
}
