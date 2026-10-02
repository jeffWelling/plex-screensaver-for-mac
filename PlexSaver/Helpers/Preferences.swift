import Foundation
import ScreenSaver
import CryptoKit

enum ImageSourceType: String, Codable, CaseIterable, Sendable {
    case fanart, posters, mixed
    var displayName: String {
        switch self { case .fanart: return "Backgrounds"; case .posters: return "Posters"; case .mixed: return "Both" }
    }
}

struct Preferences {
    // UserDefaults supports concurrent access. Keep one domain object so writes
    // and immediate reads share the same in-memory preference cache.
    private final class PreferenceDomain: @unchecked Sendable {
        let defaults = ScreenSaverDefaults(forModuleWithName: AppConstants.module) ?? UserDefaults(suiteName: AppConstants.module)!
    }
    private static let domain = PreferenceDomain()
    static var defaults: UserDefaults { domain.defaults }
    private static func simple<T>(_ key: String, default value: T) -> T { defaults.object(forKey: key) as? T ?? value }
    private static func codable<T: Codable>(_ key: String, default value: T) -> T {
        guard let string = defaults.string(forKey: key), let data = string.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else { return value }
        return decoded
    }
    private static func setCodable<T: Codable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) { defaults.set(string, forKey: key) }
    }
    static var plexServerURL: String {
        get { simple("PlexServerURL", default: "") }
        set { defaults.set(newValue, forKey: "PlexServerURL") }
    }
    static var plexAccountID: String {
        get { simple("PlexAccountID", default: "") }
        set { defaults.set(newValue, forKey: "PlexAccountID") }
    }
    static var plexServerID: String {
        get { simple("PlexServerID", default: "") }
        set { defaults.set(newValue, forKey: "PlexServerID") }
    }
    static var plexFallbackURLs: [String] {
        get { codable("PlexFallbackURLs", default: []) }
        set { setCodable(newValue, forKey: "PlexFallbackURLs") }
    }
    static var gridRows: Int {
        get { simple("GridRows", default: 3) }
        set { defaults.set(newValue, forKey: "GridRows") }
    }
    static var gridColumns: Int {
        get { simple("GridColumns", default: 4) }
        set { defaults.set(newValue, forKey: "GridColumns") }
    }
    static var gridAutoColumns: Bool {
        get { simple("GridAutoColumns", default: false) }
        set { defaults.set(newValue, forKey: "GridAutoColumns") }
    }
    static var rotationInterval: Double {
        get { simple("RotationInterval", default: 5.0) }
        set { defaults.set(newValue, forKey: "RotationInterval") }
    }
    static var imageSource: ImageSourceType {
        get { codable("ImageSource", default: .fanart) }
        set { setCodable(newValue, forKey: "ImageSource") }
    }
    static var includePostersInMixed: Bool {
        get { simple("IncludePostersInMixed", default: false) }
        set { defaults.set(newValue, forKey: "IncludePostersInMixed") }
    }
    static var selectedLibraryIds: [String] {
        get { codable("SelectedLibraryIds", default: []) }
        set { setCodable(newValue, forKey: "SelectedLibraryIds") }
    }
    static var showTitleReveal: Bool {
        get { simple("ShowTitleReveal", default: true) }
        set { defaults.set(newValue, forKey: "ShowTitleReveal") }
    }
    static var titleDisplayDuration: Double {
        get { simple("TitleDisplayDuration", default: 2.0) }
        set { defaults.set(newValue, forKey: "TitleDisplayDuration") }
    }
    static var showVersionOverlay: Bool {
        get { simple("ShowVersionOverlay", default: false) }
        set { defaults.set(newValue, forKey: "ShowVersionOverlay") }
    }
    static var showDebugHUD: Bool {
        get { simple("ShowDebugHUD", default: false) }
        set { defaults.set(newValue, forKey: "ShowDebugHUD") }
    }
    static var providerType: ProviderType {
        get { codable("ProviderType", default: .plex) }
        set { setCodable(newValue, forKey: "ProviderType") }
    }
    static var jellyfinServerURL: String {
        get { simple("JellyfinServerURL", default: "") }
        set { defaults.set(newValue, forKey: "JellyfinServerURL") }
    }
    static var jellyfinUsername: String {
        get { simple("JellyfinUsername", default: "") }
        set { defaults.set(newValue, forKey: "JellyfinUsername") }
    }
    static var jellyfinUserId: String {
        get { simple("JellyfinUserId", default: "") }
        set { defaults.set(newValue, forKey: "JellyfinUserId") }
    }

    private static var credentialRepository: CredentialRepository {
        CredentialRepository(defaults: defaults, secrets: SystemSecretStore(service: AppConstants.module))
    }
    static func readCredential(_ key: String, migrateLegacy: Bool = false, allowInteraction: Bool = false) async throws -> String {
        let repository = credentialRepository
        return try await Task.detached { try repository.read(key, migrateLegacy: migrateLegacy, allowInteraction: allowInteraction) }.value
    }
    static func saveCredential(_ key: String, value: String) async throws {
        let repository = credentialRepository
        try await Task.detached { try repository.save(key, value: value) }.value
    }
    static func clearCredential(_ key: String) async throws {
        let repository = credentialRepository
        try await Task.detached { try repository.clear(key) }.value
    }
    static var connectionProfile: ConnectionProfile {
        switch providerType {
        case .plex: return ConnectionProfile(provider: .plex, serverURL: plexServerURL, accountID: plexAccountID, serverID: plexServerID)
        case .jellyfin: return ConnectionProfile(provider: .jellyfin, serverURL: jellyfinServerURL, accountID: jellyfinUserId)
        }
    }
    static func connectionSnapshot(credentialReader: @Sendable (String) async throws -> String = { key in
        try await Preferences.readCredential(key, migrateLegacy: true)
    }) async throws -> ConnectionSnapshot {
        let profile = connectionProfile
        let token = try await credentialReader(profile.provider == .plex ? "PlexToken" : "JellyfinAccessToken")
        try Task.checkCancellation()
        guard connectionProfile == profile, connectionProfile.serverURL == profile.serverURL else { throw CancellationError() }
        return ConnectionSnapshot(provider: profile.provider, serverURL: profile.serverURL, token: token,
                                  userID: profile.provider == .jellyfin ? profile.accountID : "", accountID: profile.accountID, serverID: profile.serverID, fallbackURLs: profile.provider == .plex ? plexFallbackURLs : [])
    }
    /// Compatibility fingerprint used only to verify migration of pre-stable-ID profiles.
    static func legacyPlexAccountIdentifier(for token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isLegacyPlexAccountIdentifier(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    static func librarySelection(for profile: ConnectionProfile) -> LibrarySelection {
        if let data = defaults.data(forKey: "LibrarySelection.\(profile.namespace)"),
           let selection = try? JSONDecoder().decode(LibrarySelection.self, from: data) { return selection }
        // Import the old global selection only into the currently active profile.
        // Old empty values meant All; new explicit empty selections mean None.
        if profile == connectionProfile && !defaults.bool(forKey: "LibrarySelectionMigrated") {
            let ids = Set(selectedLibraryIds)
            return ids.isEmpty ? .all : .selected(ids)
        }
        return .all
    }
    static func saveLibrarySelection(_ selection: LibrarySelection, for profile: ConnectionProfile) {
        if let data = try? JSONEncoder().encode(selection) { defaults.set(data, forKey: "LibrarySelection.\(profile.namespace)") }
        if profile == connectionProfile { defaults.set(true, forKey: "LibrarySelectionMigrated") }
        defaults.synchronize()
    }
    static func settingsSnapshot() -> SaverSettings {
        // Migration is evaluated without writing anything while Options loads.
        let source = !defaults.bool(forKey: "ArtworkChoicesMigrated") && imageSource == .mixed && !includePostersInMixed ? ImageSourceType.fanart : imageSource
        return SaverSettings(rows: gridRows, columns: gridColumns, autoColumns: gridAutoColumns,
                             rotationInterval: rotationInterval, imageSource: source,
                             showTitleReveal: showTitleReveal, titleDisplayDuration: titleDisplayDuration,
                             librarySelection: librarySelection(for: connectionProfile))
    }
    static func saveSettings(_ settings: SaverSettings, profile: ConnectionProfile) {
        gridRows = settings.rows; gridColumns = settings.columns; gridAutoColumns = settings.autoColumns
        rotationInterval = settings.rotationInterval; imageSource = settings.imageSource
        includePostersInMixed = true; showTitleReveal = settings.showTitleReveal; titleDisplayDuration = settings.titleDisplayDuration
        saveLibrarySelection(settings.librarySelection, for: profile)
        defaults.set(true, forKey: "ArtworkChoicesMigrated")
        defaults.synchronize()
    }
}
