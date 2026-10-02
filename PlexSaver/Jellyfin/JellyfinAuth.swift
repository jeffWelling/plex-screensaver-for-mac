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

    private let transport: any NetworkTransport

    init(transport: any NetworkTransport = URLSessionTransport()) {
        self.transport = transport
    }

    static func authorizationHeader(token: String? = nil) throws -> String {
        let version = Bundle(for: MontageView.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.6.0"
        var value = "MediaBrowser Client=\"Montage\", Device=\"Mac\", DeviceId=\"\(try validatedCredential(deviceId))\", Version=\"\(try validatedCredential(version))\""
        if let token { value += ", Token=\"\(try validatedCredential(token))\"" }
        return value
    }

    /// The password is sent only for this request and never persisted.
    func authenticate(serverURL: String, username: String, password: String) async throws -> (accessToken: String, userId: String) {
        let url = try ServerEndpoint(serverURL).url(path: "/Users/AuthenticateByName")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(try Self.authorizationHeader(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        let data = try await transport.data(for: request, maximumBytes: URLSessionTransport.maximumJSONBytes)
        let response = try JSONDecoder().decode(JellyfinAuthResponse.self, from: data)
        _ = try validatedCredential(response.accessToken)
        guard !response.user.id.isEmpty else { throw MediaNetworkError.invalidResponse }
        return (accessToken: response.accessToken, userId: response.user.id)
    }
}
