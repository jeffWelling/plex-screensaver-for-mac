//
//  PlexAuth.swift
//  PlexSaver
//
//  PIN-based OAuth flow for Plex authentication.
//  Creates a PIN, opens browser for user login, polls for auth token,
//  then discovers the user's servers.
//

import Foundation
import AppKit
import os.log

struct PlexPin: Decodable {
    let id: Int
    let code: String
    let authToken: String?
}

struct PlexResource: Decodable {
    let name: String
    let provides: String
    let connections: [PlexConnection]
    let accessToken: String?
}

struct PlexConnection: Decodable {
    let uri: String
    let local: Bool
    let connectionProtocol: String?

    private enum CodingKeys: String, CodingKey {
        case uri, local
        case connectionProtocol = "protocol"
    }
}

/// Represents a discovered Plex server with its access token.
struct PlexServer: Identifiable {
    let name: String
    let uri: String
    let token: String
    let isLocal: Bool

    var id: String { uri }
}

actor PlexAuth {
    private static let clientIdentifier: String = {
        // Persist a stable client ID per machine
        let key = "PlexClientIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }()

    private static let productName = "PlexSaver"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    // MARK: - PIN Flow

    /// Step 1: Create a PIN on plex.tv
    func createPin() async throws -> PlexPin {
        guard let url = URL(string: "https://plex.tv/api/v2/pins?strong=true") else {
            throw PlexAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(Self.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlexAuthError.pinCreationFailed
        }

        return try JSONDecoder().decode(PlexPin.self, from: data)
    }

    /// Step 2: Build the browser URL for user to authenticate
    func authURL(for pin: PlexPin) -> URL? {
        var components = URLComponents(string: "https://app.plex.tv/auth")!
        // Plex uses fragment (#?) not query (?) for auth params
        let params = [
            "clientID": Self.clientIdentifier,
            "code": pin.code,
            "context[device][product]": Self.productName
        ]
        let fragment = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        components.fragment = "?" + fragment
        return components.url
    }

    /// Step 3: Poll for the auth token (returns when user completes login or timeout)
    func pollForToken(pinId: Int, code: String, maxAttempts: Int = 120) async throws -> String {
        for _ in 0..<maxAttempts {
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            guard let url = URL(string: "https://plex.tv/api/v2/pins/\(pinId)") else {
                throw PlexAuthError.invalidURL
            }

            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(Self.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
            request.setValue(code, forHTTPHeaderField: "code")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                continue
            }

            let pin = try JSONDecoder().decode(PlexPin.self, from: data)
            if let token = pin.authToken, !token.isEmpty {
                OSLog.info("PlexAuth: Got auth token from PIN flow")
                return token
            }
        }

        throw PlexAuthError.timeout
    }

    // MARK: - Server Discovery

    /// Discover all Plex Media Servers owned by the authenticated user.
    func discoverServers(authToken: String) async throws -> [PlexServer] {
        guard let url = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=0") else {
            throw PlexAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authToken, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(Self.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PlexAuthError.serverDiscoveryFailed
        }

        let resources = try JSONDecoder().decode([PlexResource].self, from: data)

        // Filter to servers only and build PlexServer objects
        var servers: [PlexServer] = []
        for resource in resources where resource.provides.contains("server") {
            let token = resource.accessToken ?? authToken
            // Prefer local connections, fall back to remote
            let localConns = resource.connections.filter { $0.local }
            let remoteConns = resource.connections.filter { !$0.local }

            for conn in localConns {
                servers.append(PlexServer(name: resource.name, uri: conn.uri, token: token, isLocal: true))
            }
            for conn in remoteConns {
                servers.append(PlexServer(name: resource.name, uri: conn.uri, token: token, isLocal: false))
            }
        }

        OSLog.info("PlexAuth: Discovered \(servers.count) server connections")
        return servers
    }
}

enum PlexAuthError: LocalizedError {
    case invalidURL
    case pinCreationFailed
    case timeout
    case serverDiscoveryFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .pinCreationFailed: return "Failed to create authentication PIN"
        case .timeout: return "Authentication timed out — please try again"
        case .serverDiscoveryFailed: return "Failed to discover Plex servers"
        }
    }
}
