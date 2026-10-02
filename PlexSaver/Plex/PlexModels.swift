//
//  PlexModels.swift
//  PlexSaver
//

import Foundation

// MARK: - Library Sections Response

struct PlexLibrarySectionsResponse: Decodable {
    let MediaContainer: PlexLibraryContainer
}

struct PlexLibraryContainer: Decodable {
    let Directory: [PlexLibrary]?
}

struct PlexLibrary: Decodable, Identifiable {
    let key: String
    let title: String
    let type: String

    var id: String { key }
}

// MARK: - Media Items Response

struct PlexMediaItemsResponse: Decodable {
    let MediaContainer: PlexMediaContainer
}

struct PlexMediaContainer: Decodable {
    let Metadata: [PlexMediaItem]?
    let totalSize: Int?
}

struct PlexMediaItem: Decodable {
    let ratingKey: String
    let title: String
    let type: String?
    let year: Int?
    let thumb: String?
    let art: String?
    let parentThumb: String?
    let grandparentThumb: String?
    let grandparentArt: String?
    let Genre: [PlexTag]?
    let Collection: [PlexTag]?
    let viewCount: Int?
    let leafCount: Int?
    let viewedLeafCount: Int?

    /// Plex omits a zero viewCount for unplayed flat items. Series count as
    /// watched only when every episode has been played, not after one episode.
    var watched: Bool? {
        if type == "show" {
            guard let total = leafCount, total > 0 else { return nil }
            return (viewedLeafCount ?? 0) >= total
        }
        return (viewCount ?? 0) > 0
    }

    /// Returns the best art path for the given image source preference.
    func artPath(for source: ImageSourceType) -> String? {
        switch source {
        case .fanart:
            return art ?? grandparentArt
        case .posters:
            return thumb ?? parentThumb ?? grandparentThumb
        case .mixed:
            let options = [art, grandparentArt, thumb, parentThumb, grandparentThumb].compactMap { $0 }
            return options.randomElement()
        }
    }
}

struct PlexTag: Decodable {
    let tag: String
}

// MARK: - Provider Conversions

extension PlexMediaItem {
    /// Convert to provider-agnostic MediaItem
    func toMediaItem() -> MediaItem {
        var paths: [ImageSourceType: String] = [:]

        // Fanart: prefer art, fall back to grandparentArt
        if let artPath = art ?? grandparentArt {
            paths[.fanart] = artPath
        }

        // Posters: prefer thumb, fall back to parentThumb, grandparentThumb
        if let posterPath = thumb ?? parentThumb ?? grandparentThumb {
            paths[.posters] = posterPath
        }

        return MediaItem(
            id: ratingKey,
            title: title,
            year: year,
            artPaths: paths,
            mediaType: type.map { $0 == "show" ? "series" : $0.lowercased() },
            genres: Genre?.map(\.tag),
            collections: Collection?.map(\.tag),
            isWatched: watched
        )
    }
}

extension PlexLibrary {
    /// Convert to provider-agnostic MediaLibrary
    func toMediaLibrary() -> MediaLibrary {
        MediaLibrary(id: key, name: title, type: type)
    }
}
