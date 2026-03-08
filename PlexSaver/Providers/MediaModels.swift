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

    /// Returns the art path for the given source type, or a random available path for .mixed
    func artPath(for source: ImageSourceType) -> String? {
        switch source {
        case .mixed:
            return artPaths.values.randomElement()
        default:
            return artPaths[source]
        }
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
