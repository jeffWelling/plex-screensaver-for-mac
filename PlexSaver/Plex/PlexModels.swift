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
