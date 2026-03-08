//
//  JellyfinAuth.swift
//  PlexSaver
//

import Foundation

/// Handles Jellyfin username/password authentication
actor JellyfinAuth {
    /// Persistent device identifier (stored in UserDefaults)
    static var deviceId: String {
        let key = "JellyfinDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

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
