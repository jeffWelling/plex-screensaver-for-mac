//
//  PlexClient.swift
//  PlexSaver
//

import Foundation
import AppKit
import os.log

actor PlexClient {
    private let serverURL: String
    private let token: String
    private let session: URLSession

    init(serverURL: String, token: String) {
        // Strip trailing slash
        self.serverURL = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    func testConnection() async throws -> Bool {
        let _ = try await fetchLibraries()
        return true
    }

    func fetchLibraries() async throws -> [PlexLibrary] {
        let data = try await request(path: "/library/sections")
        let response = try JSONDecoder().decode(PlexLibrarySectionsResponse.self, from: data)
        return response.MediaContainer.Directory ?? []
    }

    func fetchAllItems(sectionId: String) async throws -> [PlexMediaItem] {
        let data = try await request(path: "/library/sections/\(sectionId)/all")
        let response = try JSONDecoder().decode(PlexMediaItemsResponse.self, from: data)
        return response.MediaContainer.Metadata ?? []
    }

    func fetchImage(imagePath: String, width: Int, height: Int) async throws -> NSImage {
        let transcodeURL = buildTranscodeURL(imagePath: imagePath, width: width, height: height)
        guard let url = URL(string: transcodeURL) else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PlexError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        guard let image = NSImage(data: data) else {
            throw PlexError.invalidImageData
        }

        return image
    }

    // MARK: - Private Helpers

    private func request(path: String) async throws -> Data {
        guard let url = URL(string: "\(serverURL)\(path)") else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PlexError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return data
    }

    private func buildTranscodeURL(imagePath: String, width: Int, height: Int) -> String {
        let encodedPath = imagePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? imagePath
        return "\(serverURL)/photo/:/transcode?url=\(encodedPath)&width=\(width)&height=\(height)&minSize=1"
    }
}

// MARK: - Errors

enum PlexError: LocalizedError {
    case invalidURL
    case httpError(Int)
    case invalidImageData
    case noLibraries
    case noMediaItems

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Plex server URL"
        case .httpError(let code): return "HTTP error \(code)"
        case .invalidImageData: return "Invalid image data received"
        case .noLibraries: return "No libraries found on server"
        case .noMediaItems: return "No media items found"
        }
    }
}
