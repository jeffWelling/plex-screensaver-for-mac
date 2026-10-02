import SwiftUI

protocol ConfigurationServices: Sendable {
    func plexSignIn(status: @escaping @Sendable (String) async -> Void) async throws -> String
    func plexAccountID(token: String) async throws -> String
    func plexServers(token: String) async throws -> [PlexServer]
    func libraries(connection: ConnectionSnapshot) async throws -> [MediaLibrary]
    func jellyfinSignIn(serverURL: String, username: String, password: String) async throws -> (accessToken: String, userId: String)
}

struct DefaultConfigurationServices: ConfigurationServices {
    func plexSignIn(status: @escaping @Sendable (String) async -> Void) async throws -> String {
        let auth = PlexAuth()
        let pin = try await auth.createPin()
        try Task.checkCancellation()
        guard let url = await auth.authURL(for: pin) else { throw PlexAuthError.invalidURL }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
        await status("Waiting for you to sign in…")
        return try await auth.pollForToken(pinId: pin.id, code: pin.code)
    }
    func plexAccountID(token: String) async throws -> String { try await PlexAuth().fetchAccountID(authToken: token) }
    func plexServers(token: String) async throws -> [PlexServer] { try await PlexAuth().discoverServers(authToken: token) }
    func libraries(connection: ConnectionSnapshot) async throws -> [MediaLibrary] {
        switch connection.provider {
        case .plex: return try await PlexClient(serverURL: connection.serverURL, token: connection.token, fallbackURLs: connection.fallbackURLs).fetchLibraries().map { $0.toMediaLibrary() }
        case .jellyfin: return try await JellyfinProvider(serverURL: connection.serverURL, accessToken: connection.token, userId: connection.userID).fetchLibraries()
        }
    }
    func jellyfinSignIn(serverURL: String, username: String, password: String) async throws -> (accessToken: String, userId: String) {
        try await JellyfinAuth().authenticate(serverURL: serverURL, username: username, password: password)
    }
}

protocol ConfigurationCredentials: Sendable {
    func read(_ key: String, allowInteraction: Bool) async throws -> String
    func save(_ key: String, value: String) async throws
    func clear(_ key: String) async throws
}
struct DefaultConfigurationCredentials: ConfigurationCredentials {
    func read(_ key: String, allowInteraction: Bool) async throws -> String { try await Preferences.readCredential(key, migrateLegacy: true, allowInteraction: allowInteraction) }
    func save(_ key: String, value: String) async throws { try await Preferences.saveCredential(key, value: value) }
    func clear(_ key: String) async throws { try await Preferences.clearCredential(key) }
}

enum ConfigurationConnectionState: Equatable {
    case idle, testing, connected(Int), failed(String)
    var message: String {
        switch self {
        case .idle: return "Ready to test connection"
        case .testing: return "Loading libraries…"
        case .connected(let count): return "Connected · \(count) libraries"
        case .failed(let message): return message
        }
    }
}

private struct JellyfinConnectionMetadata: Equatable {
    let serverURL: String
    let username: String
    let userID: String
    var profile: ConnectionProfile { ConnectionProfile(provider: .jellyfin, serverURL: serverURL, accountID: userID) }
}
private struct StagedJellyfinConnection {
    let metadata: JellyfinConnectionMetadata
    let token: String
}

@MainActor final class ConfigurationViewModel: ObservableObject {
    @Published var plexServerURL = "" { didSet { if plexServerURL != oldValue { connectionInputChanged(provider: .plex) } } }
    @Published var plexToken = ""
    @Published var gridRows = 3
    @Published var gridColumns = 4
    @Published var gridAutoColumns = false
    @Published var rotationInterval = 5.0
    @Published var imageSource: ImageSourceType = .fanart
    @Published var selectedLibraryIds: Set<String> = []
    @Published var allLibraries = true
    @Published var showTitleReveal = true
    @Published var titleDisplayDuration = 2.0
    @Published var discoveredLibraries: [MediaLibrary] = []
    @Published var providerType: ProviderType = .plex { didSet { if providerType != oldValue { providerChanged(from: oldValue) } } }
    @Published var isSigningIn = false
    @Published var signInStatus = ""
    @Published var isSignedIn = false
    @Published var discoveredServers: [PlexServer] = []
    @Published var selectedServerURI = ""
    @Published var jellyfinServerURL = "" { didSet { if jellyfinServerURL != oldValue { connectionInputChanged(provider: .jellyfin) } } }
    @Published var jellyfinUsername = "" { didSet { if jellyfinUsername != oldValue { connectionInputChanged(provider: .jellyfin) } } }
    @Published var jellyfinPassword = ""
    @Published var isJellyfinConnected = false
    @Published var isJellyfinConnecting = false
    @Published var jellyfinStatus = ""
    @Published var connectionState: ConfigurationConnectionState = .idle
    @Published var storageMessage = ""
    @Published var isApplying = false
    @Published var isRestoring = false
    @Published var diagnosticSummary = ""
    @Published var cacheMessage = ""
    @Published var isManagingCache = false

    var isTesting: Bool { connectionState == .testing }
    var testMessage: String { connectionState.message }
    var testResult: Bool? { switch connectionState { case .connected: return true; case .failed: return false; default: return nil } }
    var isConnected: Bool { providerType == .plex ? isSignedIn : isJellyfinConnected }
    var usesHTTP: Bool {
        let text = providerType == .plex ? plexServerURL : jellyfinServerURL
        return (try? ServerEndpoint(text).isSecure) == false
    }
    private(set) var authToken = ""
    private var pendingAuthToken: String?
    private var pendingPlexAccountID: String?
    private var jellyfinToken = ""
    private var jellyfinUserID = ""
    private var installedJellyfinConnection = JellyfinConnectionMetadata(serverURL: "", username: "", userID: "")
    private var stagedJellyfinConnection: StagedJellyfinConnection?
    private var updatesConnectionInternally = false
    private var plexAccountID = ""
    private var plexServerID = ""
    private var plexFallbackURLs: [String] = []
    private var dirtyCredentials: Set<String> = []
    private var profileSelections: [ConnectionProfile: LibrarySelection] = [:]
    private let services: any ConfigurationServices
    private let credentials: any ConfigurationCredentials
    private var operationTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?
    private var cacheOperationID = UUID()
    private var generation = 0
    private var initialized = false

    init(services: any ConfigurationServices = DefaultConfigurationServices(), credentials: any ConfigurationCredentials = DefaultConfigurationCredentials(), restoreCredentials: Bool = true) {
        self.services = services; self.credentials = credentials
        let settings = Preferences.settingsSnapshot()
        gridRows = settings.rows; gridColumns = settings.columns; gridAutoColumns = settings.autoColumns
        rotationInterval = settings.rotationInterval; imageSource = settings.imageSource
        showTitleReveal = settings.showTitleReveal; titleDisplayDuration = settings.titleDisplayDuration
        providerType = Preferences.providerType
        plexServerURL = Preferences.plexServerURL; selectedServerURI = plexServerURL
        plexAccountID = Preferences.plexAccountID; plexServerID = Preferences.plexServerID; plexFallbackURLs = Preferences.plexFallbackURLs
        jellyfinServerURL = Preferences.jellyfinServerURL; jellyfinUsername = Preferences.jellyfinUsername
        jellyfinUserID = Preferences.jellyfinUserId
        installedJellyfinConnection = JellyfinConnectionMetadata(serverURL: jellyfinServerURL, username: jellyfinUsername, userID: jellyfinUserID)
        loadSelection(for: currentProfile)
        initialized = true
        if restoreCredentials { restore() }
    }
    deinit { operationTask?.cancel(); restoreTask?.cancel(); cacheTask?.cancel(); diagnosticTask?.cancel() }

    var currentProfile: ConnectionProfile {
        ConnectionProfile(provider: providerType, serverURL: providerType == .plex ? plexServerURL : jellyfinServerURL,
                          accountID: providerType == .plex ? plexAccountID : jellyfinUserID, serverID: providerType == .plex ? plexServerID : "")
    }
    private var currentSelection: LibrarySelection { allLibraries ? .all : .selected(selectedLibraryIds) }
    private var currentConnection: ConnectionSnapshot {
        ConnectionSnapshot(provider: providerType, serverURL: currentProfile.serverURL,
                           token: providerType == .plex ? plexToken : jellyfinToken,
                           userID: jellyfinUserID, accountID: currentProfile.accountID, serverID: currentProfile.serverID, fallbackURLs: providerType == .plex ? plexFallbackURLs : [])
    }
    private func loadSelection(for profile: ConnectionProfile) {
        let selection = profileSelections[profile] ?? Preferences.librarySelection(for: profile)
        switch selection { case .all: allLibraries = true; selectedLibraryIds = []; case .selected(let ids): allLibraries = false; selectedLibraryIds = ids }
    }
    private func cancelOperations() {
        generation += 1
        operationTask?.cancel(); operationTask = nil
        restoreTask?.cancel(); restoreTask = nil
        isSigningIn = false; isJellyfinConnecting = false; isRestoring = false
        connectionState = .idle
    }
    func cancelPendingOperations() {
        let canceledPlexSignIn = isSigningIn || pendingAuthToken != nil
        let canceledJellyfinSignIn = isJellyfinConnecting
        cancelOperations(); cacheTask?.cancel(); diagnosticTask?.cancel()
        pendingAuthToken = nil; pendingPlexAccountID = nil; discoveredServers = []; jellyfinPassword = ""
        isSignedIn = !plexServerURL.isEmpty && !plexToken.isEmpty
        if canceledPlexSignIn { signInStatus = "Sign-in canceled" }
        if canceledJellyfinSignIn { jellyfinStatus = "Connection canceled" }
        cacheOperationID = UUID(); isManagingCache = false
    }
    private func accepts(_ id: Int, provider: ProviderType) -> Bool { id == generation && provider == providerType && !Task.isCancelled }
    private func connectionInputChanged(provider: ProviderType) {
        guard initialized, !updatesConnectionInternally else { return }
        if provider == .jellyfin {
            let bound = stagedJellyfinConnection?.metadata ?? installedJellyfinConnection
            let editedEndpoint = (try? ServerEndpoint(jellyfinServerURL).canonicalURLString) ?? jellyfinServerURL
            let boundEndpoint = (try? ServerEndpoint(bound.serverURL).canonicalURLString) ?? bound.serverURL
            if editedEndpoint != boundEndpoint || jellyfinUsername != bound.username {
                // Draft fields never retarget an existing or newly authenticated
                // credential. Only a successful login establishes a new binding.
                jellyfinToken = ""; jellyfinUserID = ""; stagedJellyfinConnection = nil
                dirtyCredentials.remove("JellyfinAccessToken")
                isJellyfinConnected = false; discoveredLibraries = []
                jellyfinStatus = "Connection details changed. Connect again."
            }
        }
        if provider == providerType, isRestoring || isTesting || isJellyfinConnecting {
            cancelOperations(); discoveredLibraries = []
            if provider == .jellyfin { jellyfinStatus = "Connection details changed. Connect again." }
        }
    }
    private func providerChanged(from oldProvider: ProviderType) {
        guard initialized else { return }
        let oldProfile = ConnectionProfile(provider: oldProvider, serverURL: oldProvider == .plex ? plexServerURL : jellyfinServerURL,
                                           accountID: oldProvider == .plex ? plexAccountID : jellyfinUserID, serverID: oldProvider == .plex ? plexServerID : "")
        profileSelections[oldProfile] = currentSelection
        cancelOperations(); discoveredLibraries = []; jellyfinPassword = ""
        pendingAuthToken = nil; pendingPlexAccountID = nil; discoveredServers = []
        loadSelection(for: currentProfile)
        if isConnected { testConnection() } else { restore() }
    }
    func retryCredentials() { restore(allowInteraction: true) }
    private func restore(allowInteraction: Bool = false) {
        cancelOperations()
        let id = generation, provider = providerType
        let originalProfile = currentProfile, originalUsername = jellyfinUsername
        isRestoring = true
        restoreTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                if provider == .plex {
                    let serverToken = try await credentials.read("PlexToken", allowInteraction: allowInteraction)
                    let accountToken = try await credentials.read("PlexAuthToken", allowInteraction: allowInteraction)
                    guard accepts(id, provider: provider), currentProfile == originalProfile, currentProfile.serverURL == originalProfile.serverURL else { return }
                    let inheritedSelection = currentSelection
                    let legacyIdentity = plexAccountID.isEmpty || Preferences.isLegacyPlexAccountIdentifier(plexAccountID)
                    let verifiedLegacyBinding = plexAccountID.isEmpty || plexAccountID == Preferences.legacyPlexAccountIdentifier(for: accountToken)
                    var resolvedIdentity = plexAccountID
                    if legacyIdentity, !accountToken.isEmpty {
                        do { resolvedIdentity = try await services.plexAccountID(token: accountToken) }
                        catch {
                            guard accepts(id, provider: provider) else { return }
                            signInStatus = "Saved connection restored. Sign in with Plex when online to refresh your account."
                        }
                    }
                    guard accepts(id, provider: provider), currentProfile == originalProfile,
                          currentProfile.serverURL == originalProfile.serverURL else { return }
                    plexToken = serverToken; authToken = accountToken
                    if !resolvedIdentity.isEmpty, resolvedIdentity != plexAccountID {
                        plexAccountID = resolvedIdentity
                        if verifiedLegacyBinding { profileSelections[currentProfile] = inheritedSelection }
                    }
                    isSignedIn = !serverToken.isEmpty && !plexServerURL.isEmpty
                } else {
                    let token = try await credentials.read("JellyfinAccessToken", allowInteraction: allowInteraction)
                    guard accepts(id, provider: provider), currentProfile == originalProfile, currentProfile.serverURL == originalProfile.serverURL, jellyfinUsername == originalUsername else { return }
                    jellyfinToken = token
                    isJellyfinConnected = !token.isEmpty && !jellyfinUserID.isEmpty && !jellyfinServerURL.isEmpty
                }
                isRestoring = false; storageMessage = ""
                loadSelection(for: currentProfile)
                if isConnected { testConnection() } else { refreshDiagnostics() }
            } catch {
                guard accepts(id, provider: provider) else { return }
                isRestoring = false; storageMessage = error.localizedDescription
            }
        }
    }

    private func publishSignInStatus(_ message: String, generation id: Int) {
        if accepts(id, provider: .plex) { signInStatus = message }
    }
    func signInWithPlex() {
        guard providerType == .plex else { return }
        cancelOperations(); pendingAuthToken = nil; pendingPlexAccountID = nil
        let id = generation
        isSigningIn = true; signInStatus = "Opening browser…"
        operationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                let token = try await services.plexSignIn { [weak self] message in
                    await self?.publishSignInStatus(message, generation: id)
                }
                guard accepts(id, provider: .plex) else { return }
                signInStatus = "Confirming your Plex account…"
                let accountID = try await services.plexAccountID(token: token)
                guard accepts(id, provider: .plex) else { return }
                signInStatus = "Discovering servers…"
                let servers = try await services.plexServers(token: token)
                guard accepts(id, provider: .plex) else { return }
                isSigningIn = false; discoveredServers = servers
                if !servers.isEmpty { pendingAuthToken = token; pendingPlexAccountID = accountID; isSignedIn = false }
                signInStatus = servers.isEmpty ? "No reachable secure servers found" : "Select a server"
                if servers.count == 1 { selectServer(servers[0]) }
            } catch {
                guard accepts(id, provider: .plex) else { return }
                isSigningIn = false; signInStatus = error.localizedDescription
            }
        }
    }
    func selectServer(_ server: PlexServer) {
        profileSelections[currentProfile] = currentSelection
        cancelOperations()
        if let pendingAuthToken, let pendingPlexAccountID {
            authToken = pendingAuthToken; plexAccountID = pendingPlexAccountID
            dirtyCredentials.insert("PlexAuthToken")
            self.pendingAuthToken = nil; self.pendingPlexAccountID = nil
        }
        plexServerURL = server.uri; plexToken = server.token; selectedServerURI = server.uri
        plexServerID = server.id; plexFallbackURLs = server.connections.map(\.uri)
        dirtyCredentials.insert("PlexToken"); isSignedIn = true
        signInStatus = "Connected to \(server.name)"; loadSelection(for: currentProfile)
        testConnection()
    }
    func changeServer() {
        guard !authToken.isEmpty else { signInWithPlex(); return }
        cancelOperations(); discoveredLibraries = []
        let id = generation, token = authToken
        isSigningIn = true; signInStatus = "Discovering servers…"
        operationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                let servers = try await services.plexServers(token: token)
                guard accepts(id, provider: .plex) else { return }
                discoveredServers = servers; isSigningIn = false
                isSignedIn = false; signInStatus = servers.isEmpty ? "No reachable secure servers found" : "Select a server"
            } catch {
                guard accepts(id, provider: .plex) else { return }
                isSigningIn = false; signInStatus = error.localizedDescription
            }
        }
    }
    func signOut() { disconnect(provider: .plex) }
    func disconnectJellyfin() { disconnect(provider: .jellyfin) }
    private func disconnect(provider: ProviderType) {
        let profile = currentProfile
        let cacheProfiles: Set<ConnectionProfile> = provider == .jellyfin ? [profile, installedJellyfinConnection.profile] : [profile]
        cancelOperations(); pendingAuthToken = nil; pendingPlexAccountID = nil; discoveredLibraries = []; discoveredServers = []
        if provider == .plex {
            plexToken = ""; authToken = ""; isSignedIn = false; plexServerURL = ""; selectedServerURI = ""; plexAccountID = ""
            Preferences.plexServerURL = ""; Preferences.plexAccountID = ""; plexServerID = ""; plexFallbackURLs = []; Preferences.plexServerID = ""; Preferences.plexFallbackURLs = []
        } else {
            jellyfinToken = ""; jellyfinUserID = ""; jellyfinPassword = ""; isJellyfinConnected = false
            Preferences.jellyfinUserId = ""
            stagedJellyfinConnection = nil
            installedJellyfinConnection = JellyfinConnectionMetadata(serverURL: installedJellyfinConnection.serverURL, username: installedJellyfinConnection.username, userID: "")
        }
        let keys = provider == .plex ? ["PlexToken", "PlexAuthToken"] : ["JellyfinAccessToken"]
        dirtyCredentials.subtract(keys)
        storageMessage = ""; isApplying = true
        operationTask = Task { [weak self] in
            guard let self else { return }
            var errors: [String] = []
            for key in keys { do { try await credentials.clear(key) } catch { errors.append(error.localizedDescription) } }
            for cacheProfile in cacheProfiles {
                let cache = await DiskCacheCoordinator.shared.cache(for: cacheProfile.namespace)
                await cache.clear()
            }
            isApplying = false
            storageMessage = errors.joined(separator: "\n")
            Preferences.defaults.synchronize()
            NotificationCenter.default.post(name: .montageConfigChanged, object: nil)
        }
    }

    func connectToJellyfin() {
        guard providerType == .jellyfin else { return }
        guard !jellyfinUsername.isEmpty, !jellyfinPassword.isEmpty else { jellyfinStatus = "Enter a username and password"; return }
        let server: String
        do { server = try ServerEndpoint(jellyfinServerURL).canonicalURLString } catch { jellyfinStatus = error.localizedDescription; return }
        cancelOperations()
        let id = generation, username = jellyfinUsername, password = jellyfinPassword
        isJellyfinConnecting = true; jellyfinStatus = "Connecting…"
        operationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                let result = try await services.jellyfinSignIn(serverURL: server, username: username, password: password)
                guard accepts(id, provider: .jellyfin), username == jellyfinUsername,
                      (try? ServerEndpoint(jellyfinServerURL).canonicalURLString) == server else { return }
                isJellyfinConnecting = false
                updatesConnectionInternally = true
                jellyfinServerURL = server; jellyfinToken = result.accessToken; jellyfinUserID = result.userId
                stagedJellyfinConnection = StagedJellyfinConnection(metadata: JellyfinConnectionMetadata(serverURL: server, username: username, userID: result.userId), token: result.accessToken)
                updatesConnectionInternally = false
                dirtyCredentials.insert("JellyfinAccessToken")
                isJellyfinConnected = true; isJellyfinConnecting = false; jellyfinStatus = "Connected"
                jellyfinPassword = ""; loadSelection(for: currentProfile); testConnection()
            } catch {
                guard accepts(id, provider: .jellyfin) else { return }
                isJellyfinConnecting = false; jellyfinPassword = ""; jellyfinStatus = error.localizedDescription
            }
        }
    }
    func testConnection() {
        let connection = currentConnection
        guard !connection.serverURL.isEmpty, !connection.token.isEmpty else { connectionState = .failed("Sign in to load your libraries"); return }
        cancelOperations()
        let id = generation
        connectionState = .testing
        operationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                let libraries = try await services.libraries(connection: connection)
                guard accepts(id, provider: connection.provider), currentProfile == connection.profile, currentProfile.serverURL == connection.profile.serverURL else { return }
                discoveredLibraries = libraries
                if !allLibraries { selectedLibraryIds.formIntersection(Set(libraries.map(\.id))) }
                connectionState = .connected(libraries.count)
                refreshDiagnostics()
            } catch {
                guard accepts(id, provider: connection.provider), currentProfile == connection.profile, currentProfile.serverURL == connection.profile.serverURL else { return }
                connectionState = .failed(error.localizedDescription)
                refreshDiagnostics()
            }
        }
    }
    func testJellyfinConnection() { testConnection() }
    func libraryBinding(for id: String) -> Binding<Bool> {
        Binding(get: { self.allLibraries || self.selectedLibraryIds.contains(id) }, set: { selected in
            if self.allLibraries { self.allLibraries = false; self.selectedLibraryIds = Set(self.discoveredLibraries.map(\.id)) }
            if selected { self.selectedLibraryIds.insert(id) } else { self.selectedLibraryIds.remove(id) }
        })
    }
    /// Single explicit flush → notify → dismiss path; no debounced writes.
    func apply(onSuccess: @escaping () -> Void) {
        guard !isApplying else { return }
        cancelPendingOperations()
        isApplying = true; storageMessage = ""
        let draftProfile = currentProfile
        let staged = stagedJellyfinConnection.flatMap { connection in
            let endpoint = (try? ServerEndpoint(jellyfinServerURL).canonicalURLString) ?? jellyfinServerURL
            return endpoint == connection.metadata.serverURL && jellyfinUsername == connection.metadata.username
                && jellyfinUserID == connection.metadata.userID && jellyfinToken == connection.token ? connection : nil
        }
        let effectiveJellyfin = staged?.metadata ?? installedJellyfinConnection
        let profile = providerType == .jellyfin ? effectiveJellyfin.profile : currentProfile
        let sameBinding = draftProfile == profile && draftProfile.serverURL == profile.serverURL
        let selection = sameBinding ? currentSelection : (profileSelections[profile] ?? Preferences.librarySelection(for: profile))
        let pending: [String: String] = ["PlexToken": plexToken, "PlexAuthToken": authToken, "JellyfinAccessToken": staged?.token ?? ""]
        let credentialKeys = dirtyCredentials.filter { $0 != "JellyfinAccessToken" || staged != nil }.sorted()
        let pendingConnections = (plexServerURL, plexAccountID, plexServerID, plexFallbackURLs,
                                  effectiveJellyfin.serverURL, effectiveJellyfin.username, effectiveJellyfin.userID, providerType)
        var selections = profileSelections
        selections[profile] = selection
        let settings = SaverSettings(rows: gridRows, columns: gridColumns, autoColumns: gridAutoColumns,
            rotationInterval: rotationInterval, imageSource: imageSource, showTitleReveal: showTitleReveal,
            titleDisplayDuration: titleDisplayDuration, librarySelection: selection)
        operationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                for key in credentialKeys { try await credentials.save(key, value: pending[key] ?? "") }
                Preferences.plexServerURL = pendingConnections.0; Preferences.plexAccountID = pendingConnections.1
                Preferences.plexServerID = pendingConnections.2; Preferences.plexFallbackURLs = pendingConnections.3
                Preferences.jellyfinServerURL = pendingConnections.4; Preferences.jellyfinUsername = pendingConnections.5; Preferences.jellyfinUserId = pendingConnections.6
                Preferences.providerType = pendingConnections.7
                for (savedProfile, selection) in selections { Preferences.saveLibrarySelection(selection, for: savedProfile) }
                Preferences.saveSettings(settings, profile: profile)
                installedJellyfinConnection = effectiveJellyfin
                stagedJellyfinConnection = nil
                updatesConnectionInternally = true
                jellyfinServerURL = effectiveJellyfin.serverURL; jellyfinUsername = effectiveJellyfin.username
                jellyfinUserID = effectiveJellyfin.userID
                updatesConnectionInternally = false
                dirtyCredentials = []; isApplying = false
                NotificationCenter.default.post(name: .montageConfigChanged, object: nil)
                onSuccess()
            } catch { isApplying = false; storageMessage = error.localizedDescription }
        }
    }
    func refreshDiagnostics() {
        let profile = currentProfile, id = generation
        diagnosticTask?.cancel()
        diagnosticTask = Task { [weak self] in await self?.readDiagnostics(profile: profile, generation: id) }
    }
    private func readDiagnostics(profile: ConnectionProfile, generation id: Int) async {
        guard !Task.isCancelled else { return }
        let cache = await DiskCacheCoordinator.shared.cache(for: profile.namespace)
        let summary = await cache.summary()
        guard !Task.isCancelled, generation == id, currentProfile == profile, currentProfile.serverURL == profile.serverURL else { return }
        let size = ByteCountFormatter.string(fromByteCount: summary.sizeBytes, countStyle: .file)
        cacheMessage = "\(summary.count) images · \(size)"
        diagnosticSummary = "Montage \(AppConstants.version) (\(AppConstants.build))\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nProvider: \(profile.provider.displayName)\nGrid: \(gridRows) × \(gridAutoColumns ? "auto" : String(gridColumns))\nArtwork: \(imageSource.displayName)\nCache: \(cacheMessage)\nCredential storage: Keychain; runtime interaction disabled\n"
    }
    func refreshArtwork() { manageCache(retest: true) }
    func clearCache() { manageCache(retest: false) }
    private func manageCache(retest: Bool) {
        let profile = currentProfile, initialGeneration = generation
        cacheTask?.cancel(); diagnosticTask?.cancel()
        cacheOperationID = UUID()
        let operationID = cacheOperationID
        isManagingCache = true
        cacheTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer { if cacheOperationID == operationID { isManagingCache = false } }
            let cache = await DiskCacheCoordinator.shared.cache(for: profile.namespace)
            guard !Task.isCancelled, generation == initialGeneration, currentProfile == profile, currentProfile.serverURL == profile.serverURL else { return }
            await cache.clear()
            guard !Task.isCancelled, generation == initialGeneration, currentProfile == profile, currentProfile.serverURL == profile.serverURL else { return }
            // Clear disk first, then restart running previews to invalidate their
            // fresh memory images. The same coordinator handles all displays.
            NotificationCenter.default.post(name: .montageConfigChanged, object: nil)
            if retest { testConnection() }
            await readDiagnostics(profile: profile, generation: generation)
        }
    }
    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticSummary, forType: .string)
    }
}
