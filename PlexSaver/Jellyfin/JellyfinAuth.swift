//
//  JellyfinAuth.swift
//  PlexSaver
//

import Foundation
import ScreenSaver

/// Handles Jellyfin username/password authentication
actor JellyfinAuth {
    /// Persistent device identifier, stored in the shared module preference
    /// domain (`ScreenSaverDefaults(forModuleWithName:)`) rather than the host
    /// process's `UserDefaults.standard`. The config sheet runs in System
    /// Settings and the saver in legacyScreenSaver; persisting to `.standard`
    /// minted a *different* DeviceId in each host, so the token issued against
    /// the config host's id was presented at runtime with the saver host's id —
    /// producing duplicate Jellyfin device registrations (N1). A legacy value in
    /// `.standard` is migrated on first read.
    ///
    /// A `static let` so the generate-and-store happens exactly once even under
    /// concurrent first access.
    static let deviceId: String = {
        let key = "JellyfinDeviceId"
        let store = ScreenSaverDefaults(forModuleWithName: AppConstants.module)
        if let existing = store?.string(forKey: key), !existing.isEmpty {
            return existing
        }
        // Migrate a legacy value written to the host's standard domain.
        if let legacy = UserDefaults.standard.string(forKey: key), !legacy.isEmpty {
            store?.set(legacy, forKey: key)
            store?.synchronize()
            return legacy
        }
        let newId = UUID().uuidString
        if let store {
            store.set(newId, forKey: key)
            store.synchronize()
        } else {
            UserDefaults.standard.set(newId, forKey: key)
        }
        return newId
    }()

    /// Authenticate with username and password
    /// Returns (accessToken, userId) on success
    func authenticate(serverURL: String, username: String, password: String) async throws -> (accessToken: String, userId: String) {
        let baseURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/Users/AuthenticateByName") else {
            throw JellyfinError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Initial auth header without token
        let authHeader = "MediaBrowser Client=\"Montage\", Device=\"Mac\", DeviceId=\"\(JellyfinAuth.deviceId)\", Version=\"1.0\""
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let body: [String: String] = [
            "Username": username,
            "Pw": password
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw JellyfinError.authenticationFailed
        }

        let authResponse = try JSONDecoder().decode(JellyfinAuthResponse.self, from: data)

        return (accessToken: authResponse.accessToken, userId: authResponse.user.id)
    }
}
