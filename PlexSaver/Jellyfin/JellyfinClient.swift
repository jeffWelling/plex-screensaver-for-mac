//
//  JellyfinClient.swift
//  PlexSaver
//

import AppKit

/// Actor for Jellyfin API communication
actor JellyfinClient {
    private let serverURL: String
    private let accessToken: String
    private let userId: String
    private let session: URLSession

    init(serverURL: String, accessToken: String, userId: String) {
        self.serverURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.accessToken = accessToken
        self.userId = userId
        self.session = URLSession.shared
    }

    /// Fetch available media libraries (views)
    func fetchLibraries() async throws -> [JellyfinLibrary] {
        let data = try await request(path: "/Users/\(userId)/Views")
        let response = try JSONDecoder().decode(JellyfinViewsResponse.self, from: data)
        return response.items
    }

    /// Fetch all media items in a library, paging until the full set is
    /// retrieved (Jellyfin caps a single response, so a fixed Limit silently
    /// truncates large libraries).
    func fetchAllItems(libraryId: String) async throws -> [JellyfinItem] {
        let pageSize = 500
        var startIndex = 0
        var allItems: [JellyfinItem] = []

        while true {
            var components = URLComponents()
            components.path = "/Users/\(userId)/Items"
            components.queryItems = [
                URLQueryItem(name: "ParentId", value: libraryId),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,MusicAlbum"),
                URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio"),
                URLQueryItem(name: "StartIndex", value: String(startIndex)),
                URLQueryItem(name: "Limit", value: String(pageSize))
            ]

            guard let query = components.percentEncodedQuery else { break }
            let data = try await request(path: "/Users/\(userId)/Items?\(query)")
            let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)

            allItems.append(contentsOf: response.items)
            startIndex += response.items.count

            if response.items.isEmpty || allItems.count >= response.totalRecordCount {
                break
            }
        }

        return allItems
    }

    /// Fetch an image — Jellyfin images are unauthenticated
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        let imageURL = "\(serverURL)\(path)?maxWidth=\(width)&maxHeight=\(height)&format=Jpg&quality=90"

        guard let url = URL(string: imageURL) else {
            throw JellyfinError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw JellyfinError.httpError(statusCode)
        }

        guard let image = NSImage(data: data) else {
            throw JellyfinError.invalidImageData
        }

        return image
    }

    // MARK: - Private

    /// Make an authenticated request to the Jellyfin API
    private func request(path: String) async throws -> Data {
        guard let url = URL(string: "\(serverURL)\(path)") else {
            throw JellyfinError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader(), forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw JellyfinError.httpError(statusCode)
        }

        return data
    }

    /// Build the MediaBrowser authorization header
    private func authorizationHeader() -> String {
        let deviceId = JellyfinAuth.deviceId
        return "MediaBrowser Client=\"Montage\", Device=\"Mac\", DeviceId=\"\(deviceId)\", Version=\"1.0\", Token=\"\(accessToken)\""
    }
}

// MARK: - Errors

enum JellyfinError: LocalizedError {
    case invalidURL
    case httpError(Int)
    case invalidImageData
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Jellyfin server URL"
        case .httpError(let code): return "Jellyfin HTTP error: \(code)"
        case .invalidImageData: return "Invalid image data from Jellyfin"
        case .authenticationFailed: return "Jellyfin authentication failed"
        }
    }
}
