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
import ScreenSaver
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
    let clientIdentifier: String?
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

    let id: String
    let connections: [PlexConnection]

    init(name: String, uri: String, token: String, isLocal: Bool,
         id: String? = nil, connections: [PlexConnection] = []) {
        self.name = name
        self.uri = uri
        self.token = token
        self.isLocal = isLocal
        self.id = id ?? uri
        self.connections = connections
    }
}

actor PlexAuth {
    private static let clientIdentifier: String = {
        // Persist a stable client ID per machine in the shared module preference
        // domain so the config-time flows (PIN + discovery) see one identifier
        // across host processes. Migrates a legacy value from the host's standard
        // domain on first read (N1 — same domain-split hygiene as the Jellyfin
        // DeviceId; Plex's is only used during config so the impact is minor).
        let key = "PlexClientIdentifier"
        let store = ScreenSaverDefaults(forModuleWithName: AppConstants.module)
        if let existing = store?.string(forKey: key), !existing.isEmpty {
            return existing
        }
        if let legacy = UserDefaults.standard.string(forKey: key), !legacy.isEmpty {
            store?.set(legacy, forKey: key)
            store?.synchronize()
            return legacy
        }
        let newID = UUID().uuidString
        if let store {
            store.set(newID, forKey: key)
            store.synchronize()
        } else {
            UserDefaults.standard.set(newID, forKey: key)
        }
        return newID
    }()

    private static let productName = "Montage"
    private let transport: any NetworkTransport
    private let pollingTimeout: Duration

    init(transport: any NetworkTransport = URLSessionTransport(), pollingTimeout: Duration = .seconds(120)) {
        self.transport = transport
        self.pollingTimeout = min(.seconds(120), max(.milliseconds(1), pollingTimeout))
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

        let data = try await transport.data(for: request, maximumBytes: URLSessionTransport.maximumJSONBytes)

        return try JSONDecoder().decode(PlexPin.self, from: data)
    }

    /// Step 2: Build the browser URL for user to authenticate
    func authURL(for pin: PlexPin) -> URL? {
        var components = URLComponents(string: "https://app.plex.tv/auth")!
        // Plex uses fragment (#?) not query (?) for auth params
        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "clientID", value: Self.clientIdentifier),
            URLQueryItem(name: "code", value: pin.code),
            URLQueryItem(name: "context[device][product]", value: Self.productName)
        ]
        components.percentEncodedFragment = "?" + (query.percentEncodedQuery ?? "")
        return components.url
    }

    /// Step 3: Poll for the auth token (returns when user completes login or timeout)
    func pollForToken(pinId: Int, code: String, maxAttempts: Int = 120) async throws -> String {
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: pollingTimeout)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.pollUntilClaimed(pinId: pinId, code: code,
                                                maxAttempts: maxAttempts, deadline: deadline)
            }
            group.addTask {
                try await clock.sleep(until: deadline)
                throw PlexAuthError.timeout
            }
            defer { group.cancelAll() }
            guard let token = try await group.next() else { throw PlexAuthError.timeout }
            return token
        }
    }

    private func pollUntilClaimed(pinId: Int, code: String, maxAttempts: Int,
                                  deadline: ContinuousClock.Instant) async throws -> String {
        let clock = ContinuousClock()
        for _ in 0..<max(0, min(maxAttempts, 120)) {
            guard clock.now < deadline else { throw PlexAuthError.timeout }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)

            guard let url = URL(string: "https://plex.tv/api/v2/pins/\(pinId)") else {
                throw PlexAuthError.invalidURL
            }

            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(Self.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
            request.setValue(try validatedCredential(code), forHTTPHeaderField: "code")

            let data: Data
            do {
                data = try await transport.data(for: request, maximumBytes: URLSessionTransport.maximumJSONBytes)
            } catch MediaNetworkError.unavailable {
                continue
            } catch MediaNetworkError.missingArtwork {
                throw PlexAuthError.timeout
            } catch MediaNetworkError.throttled(let retryAfter) {
                try await Task.sleep(nanoseconds: UInt64(min(10, retryAfter ?? 2) * 1_000_000_000))
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

    /// Resolve the signed-in Plex account independently of its rotating token.
    /// https://developer.plex.tv/pms/ documents this authenticated user endpoint.
    func fetchAccountID(authToken: String) async throws -> String {
        try Task.checkCancellation()
        guard let url = URL(string: "https://plex.tv/api/v2/user") else {
            throw PlexAuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(Self.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(try validatedCredential(authToken), forHTTPHeaderField: "X-Plex-Token")
        let data = try await transport.data(for: request, maximumBytes: URLSessionTransport.maximumJSONBytes)
        try Task.checkCancellation()
        guard let account = try? JSONDecoder().decode(PlexAccountIdentity.self, from: data), account.id > 0 else {
            throw MediaNetworkError.invalidResponse
        }
        return String(account.id)
    }

    // MARK: - Server Discovery

    /// Discover all Plex Media Servers owned by the authenticated user.
    func discoverServers(authToken: String) async throws -> [PlexServer] {
        guard let url = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=0") else {
            throw PlexAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(try validatedCredential(authToken), forHTTPHeaderField: "X-Plex-Token")
        request.setValue(Self.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")

        let data = try await transport.data(for: request, maximumBytes: URLSessionTransport.maximumJSONBytes)

        let resources = try JSONDecoder().decode([PlexResource].self, from: data)

        var servers: [PlexServer] = []
        for resource in resources where resource.provides.split(separator: ",").contains("server") {
            try Task.checkCancellation()
            let token = try validatedCredential(resource.accessToken ?? authToken)
            let valid = resource.connections.filter { (try? ServerEndpoint($0.uri)) != nil }
            let secure = valid.filter { (try? ServerEndpoint($0.uri).isSecure) == true }
            // HTTP-only servers remain selectable with the Options warning.
            // Credentials are never sent to HTTP while probing discovery.
            let ranked = (secure.isEmpty ? valid : secure).sorted {
                if $0.local != $1.local { return $0.local }
                return $0.uri < $1.uri
            }
            guard let first = ranked.first else { continue }
            let reachable = secure.isEmpty ? nil : await reachableConnection(in: Array(ranked.prefix(4)), token: token)
            try Task.checkCancellation()
            let selected = reachable ?? first
            servers.append(PlexServer(name: resource.name, uri: selected.uri, token: token,
                                      isLocal: selected.local, id: resource.clientIdentifier,
                                      connections: ranked))
        }

        OSLog.info("PlexAuth: Discovered \(servers.count) servers")
        return servers
    }
    private func reachableConnection(in connections: [PlexConnection], token: String) async -> PlexConnection? {
        let transport = self.transport
        return await withTaskGroup(of: Int?.self) { group in
            for (index, connection) in connections.enumerated() {
                group.addTask {
                    do {
                        let url = try ServerEndpoint(connection.uri).url(path: "/identity")
                        var request = URLRequest(url: url, timeoutInterval: 5)
                        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
                        _ = try await transport.data(for: request, maximumBytes: 64 * 1024)
                        return index
                    } catch { return nil }
                }
            }
            var reachable: [Int] = []
            for await index in group { if let index { reachable.append(index) } }
            return reachable.min().map { connections[$0] }
        }
    }

}

/// Decode only the nonsecret account identifier; never retain profile data or
/// a returned token. Accept the numeric ID's string representation as well.
private struct PlexAccountIdentity: Decodable {
    let id: UInt64

    private enum CodingKeys: String, CodingKey { case id }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try? values.decode(UInt64.self, forKey: .id) {
            id = number
        } else {
            let value = try values.decode(String.self, forKey: .id)
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(value) else {
                throw MediaNetworkError.invalidResponse
            }
            id = number
        }
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
