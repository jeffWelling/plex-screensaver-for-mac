//
//  Preferences.swift
//  PlexSaver
//

import Foundation
import ScreenSaver

enum ImageSourceType: String, Codable, CaseIterable {
    case fanart = "fanart"
    case posters = "posters"
    case mixed = "mixed"

    var displayName: String {
        switch self {
        case .fanart: return "Fanart (16:9)"
        case .posters: return "Posters (2:3)"
        case .mixed: return "Mixed"
        }
    }
}

struct Preferences {
    @SimpleStorage(key: "PlexServerURL", defaultValue: "")
    static var plexServerURL: String

    /// Plex server access token — stored in the Keychain (see `secret`/`storeSecret`).
    static var plexToken: String {
        get { secret("PlexToken") }
        set { storeSecret("PlexToken", newValue) }
    }

    /// plex.tv account-wide token used for server discovery — the most
    /// sensitive credential; stored in the Keychain.
    static var plexAuthToken: String {
        get { secret("PlexAuthToken") }
        set { storeSecret("PlexAuthToken", newValue) }
    }

    @SimpleStorage(key: "GridRows", defaultValue: 3)
    static var gridRows: Int

    @SimpleStorage(key: "GridColumns", defaultValue: 4)
    static var gridColumns: Int

    /// When true, columns are computed per-display from the display bounds and
    /// the source aspect (N4), keeping the user's row count. Default false keeps
    /// the existing manual rows × columns behavior.
    @SimpleStorage(key: "GridAutoColumns", defaultValue: false)
    static var gridAutoColumns: Bool

    @SimpleStorage(key: "RotationInterval", defaultValue: 5.0)
    static var rotationInterval: Double

    @Storage(key: "ImageSource", defaultValue: .fanart)
    static var imageSource: ImageSourceType

    @SimpleStorage(key: "IncludePostersInMixed", defaultValue: false)
    static var includePostersInMixed: Bool

    @Storage(key: "SelectedLibraryIds", defaultValue: [])
    static var selectedLibraryIds: [String]

    @SimpleStorage(key: "ShowTitleReveal", defaultValue: true)
    static var showTitleReveal: Bool

    @SimpleStorage(key: "TitleDisplayDuration", defaultValue: 2.0)
    static var titleDisplayDuration: Double

    /// Show the version pill on every activation (R4). Off by default — it's
    /// noise on a screensaver — but always shown in the SaverTest app. Hidden
    /// preference; set with `defaults` for troubleshooting.
    @SimpleStorage(key: "ShowVersionOverlay", defaultValue: false)
    static var showVersionOverlay: Bool

    /// Show the read-only debug HUD (pool depth, reservation counts, last refill)
    /// on every display (A2). Off by default; hidden preference set via `defaults`.
    @SimpleStorage(key: "ShowDebugHUD", defaultValue: false)
    static var showDebugHUD: Bool

    // MARK: - Provider Selection

    @Storage(key: "ProviderType", defaultValue: .plex)
    static var providerType: ProviderType

    // MARK: - Jellyfin Settings

    @SimpleStorage(key: "JellyfinServerURL", defaultValue: "")
    static var jellyfinServerURL: String

    @SimpleStorage(key: "JellyfinUsername", defaultValue: "")
    static var jellyfinUsername: String

    /// Jellyfin access token — stored in the Keychain.
    static var jellyfinAccessToken: String {
        get { secret("JellyfinAccessToken") }
        set { storeSecret("JellyfinAccessToken", newValue) }
    }

    @SimpleStorage(key: "JellyfinUserId", defaultValue: "")
    static var jellyfinUserId: String

    // MARK: - Secret Storage (Keychain with defaults fallback)

    /// Read a secret from the Keychain, migrating any legacy plaintext value
    /// found in defaults. Falls back to the defaults value if the Keychain is
    /// unavailable so persistence never breaks.
    private static func secret(_ key: String) -> String {
        if let value = KeychainStore.get(key), !value.isEmpty {
            return value
        }
        // Legacy migration / fallback: read any plaintext value written by an
        // older build (or by the fallback path below).
        if let defaults = ScreenSaverDefaults(forModuleWithName: AppConstants.module),
           let legacy = defaults.string(forKey: key), !legacy.isEmpty {
            if KeychainStore.set(key, legacy) {
                // Migrated into the Keychain — remove the plaintext copy.
                defaults.removeObject(forKey: key)
                defaults.synchronize()
            }
            return legacy
        }
        return ""
    }

    /// Persist a secret to the Keychain, falling back to defaults if the
    /// Keychain is unavailable in this host process.
    private static func storeSecret(_ key: String, _ value: String) {
        let defaults = ScreenSaverDefaults(forModuleWithName: AppConstants.module)
        if KeychainStore.set(key, value) {
            // Stored securely — ensure no stale plaintext copy remains.
            defaults?.removeObject(forKey: key)
            defaults?.synchronize()
        } else {
            // Keychain unavailable — preserve functionality via defaults.
            defaults?.set(value, forKey: key)
            defaults?.synchronize()
        }
    }
}

// MARK: - Property Wrappers

@propertyWrapper struct Storage<T: Codable> {
    private let key: String
    private let defaultValue: T
    private let module = AppConstants.module

    init(key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: T {
        get {
            if let userDefaults = ScreenSaverDefaults(forModuleWithName: module) {
                guard let jsonString = userDefaults.string(forKey: key),
                      let jsonData = jsonString.data(using: .utf8),
                      let value = try? JSONDecoder().decode(T.self, from: jsonData) else {
                    return defaultValue
                }
                return value
            }
            return defaultValue
        }
        set {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            if let jsonData = try? encoder.encode(newValue),
               let jsonString = String(data: jsonData, encoding: .utf8),
               let userDefaults = ScreenSaverDefaults(forModuleWithName: module) {
                userDefaults.set(jsonString, forKey: key)
                userDefaults.synchronize()
            }
        }
    }
}

@propertyWrapper struct SimpleStorage<T> {
    private let key: String
    private let defaultValue: T
    private let module = AppConstants.module

    init(key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: T {
        get {
            if let userDefaults = ScreenSaverDefaults(forModuleWithName: module) {
                return userDefaults.object(forKey: key) as? T ?? defaultValue
            }
            return defaultValue
        }
        set {
            if let userDefaults = ScreenSaverDefaults(forModuleWithName: module) {
                userDefaults.set(newValue, forKey: key)
                userDefaults.synchronize()
            }
        }
    }
}
