//
//  JellyfinModels.swift
//  PlexSaver
//

import Foundation

// MARK: - Authentication

/// Response from POST /Users/AuthenticateByName
struct JellyfinAuthResponse: Decodable {
    let user: JellyfinUser
    let accessToken: String
    let sessionInfo: JellyfinSessionInfo?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case sessionInfo = "SessionInfo"
    }
}

struct JellyfinUser: Decodable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

struct JellyfinSessionInfo: Decodable {
    let id: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

// MARK: - Libraries (Views)

/// Response from GET /Users/{userId}/Views
struct JellyfinViewsResponse: Decodable {
    let items: [JellyfinLibrary]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct JellyfinLibrary: Decodable {
    let id: String
    let name: String
    let collectionType: String?
    let type: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
        case type = "Type"
    }

    /// Convert to provider-agnostic MediaLibrary
    func toMediaLibrary() -> MediaLibrary {
        MediaLibrary(id: id, name: name, type: collectionType ?? type.lowercased())
    }
}

// MARK: - Items

/// Response from GET /Users/{userId}/Items
struct JellyfinItemsResponse: Decodable {
    let items: [JellyfinItem]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct JellyfinItem: Decodable {
    let id: String
    let name: String
    let type: String
    let productionYear: Int?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case productionYear = "ProductionYear"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
    }

    /// Convert to provider-agnostic MediaItem
    func toMediaItem() -> MediaItem {
        var paths: [ImageSourceType: String] = [:]

        // Primary image -> poster
        if imageTags?["Primary"] != nil {
            paths[.posters] = "/Items/\(id)/Images/Primary"
        }

        // Backdrop -> fanart
        if let backdropTags = backdropImageTags, !backdropTags.isEmpty {
            paths[.fanart] = "/Items/\(id)/Images/Backdrop"
        }

        return MediaItem(
            id: id,
            title: name,
            year: productionYear,
            artPaths: paths
        )
    }
}
