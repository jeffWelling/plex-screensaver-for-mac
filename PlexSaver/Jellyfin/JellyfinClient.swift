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

    /// Test connectivity by fetching libraries
    func testConnection() async throws -> Bool {
        _ = try await fetchLibraries()
        return true
    }

    /// Fetch available media libraries (views)
    func fetchLibraries() async throws -> [JellyfinLibrary] {
        let data = try await request(path: "/Users/\(userId)/Views")
        let response = try JSONDecoder().decode(JellyfinViewsResponse.self, from: data)
        return response.items
    }

    /// Fetch all media items in a library
    func fetchAllItems(libraryId: String) async throws -> [JellyfinItem] {
        let path = "/Users/\(userId)/Items?ParentId=\(libraryId)&Recursive=true&IncludeItemTypes=Movie,Series,MusicAlbum&Fields=PrimaryImageAspectRatio&Limit=0"
        let data = try await request(path: path)
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        return response.items
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
    case noLibraries
    case noMediaItems

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Jellyfin server URL"
        case .httpError(let code): return "Jellyfin HTTP error: \(code)"
        case .invalidImageData: return "Invalid image data from Jellyfin"
        case .authenticationFailed: return "Jellyfin authentication failed"
        case .noLibraries: return "No libraries found on Jellyfin server"
        case .noMediaItems: return "No media items found"
        }
    }
}
