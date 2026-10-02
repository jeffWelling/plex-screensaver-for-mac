import SwiftUI

protocol ConfigurationServices: Sendable {
    func plexSignIn(status: @escaping @Sendable (String) async -> Void) async throws -> String
    func plexAccountID(token: String) async throws -> String
    func plexServers(token: String) async throws -> [PlexServer]
    func libraries(connection: ConnectionSnapshot) async throws -> [MediaLibrary]
    func jellyfinSignIn(serverURL: String, username: String, password: String) async throws -> (accessToken: String, userId: String)
    func filterOptions(connection: ConnectionSnapshot, libraryIds: [String]) async throws -> MediaFilterOptions
}
extension ConfigurationServices {
    func filterOptions(connection: ConnectionSnapshot, libraryIds: [String]) async throws -> MediaFilterOptions { MediaFilterOptions() }
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
        try await ConfigurationProviderFactory.make(connection: connection).fetchLibraries()
    }
    func jellyfinSignIn(serverURL: String, username: String, password: String) async throws -> (accessToken: String, userId: String) {
        try await JellyfinAuth().authenticate(serverURL: serverURL, username: username, password: password)
    }
    func filterOptions(connection: ConnectionSnapshot, libraryIds: [String]) async throws -> MediaFilterOptions {
        try await ConfigurationProviderFactory.make(connection: connection).fetchFilterOptions(libraryIds: libraryIds)
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
    @Published var artworkFraming: ArtworkFraming = .fill
    @Published var transitionDuration = 1.0
    @Published var mediaFilter = MediaFilter()
    @Published var filterOptions = MediaFilterOptions()
    @Published var filterStatus = ""
    @Published var localFolderBookmark: Data?
    @Published var localFolderIdentity = ""
    @Published var localFolderName = ""
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
    @Published var offlineReadiness = OfflineArtworkReadiness.empty
    @Published var preparationProgress: OfflineArtworkProgress?
    @Published var preparationMessage = ""

    var isTesting: Bool { connectionState == .testing }
    var testMessage: String { connectionState.message }
    var testResult: Bool? { switch connectionState { case .connected: return true; case .failed: return false; default: return nil } }
    var isConnected: Bool {
        switch providerType { case .plex: return isSignedIn; case .jellyfin: return isJellyfinConnected; case .local: return localFolderBookmark != nil }
    }
    var filterCapabilities: MediaFilterCapabilities { providerType.filterCapabilities }
    var usesHTTP: Bool {
        guard providerType != .local else { return false }
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
    private var credentialsToClear: Set<String> = []
    private var cacheProfilesToClear: Set<ConnectionProfile> = []
    private var disconnectedJellyfin = false
    private var profileSelections: [ConnectionProfile: LibrarySelection] = [:]
    private var profileFilters: [ConnectionProfile: MediaFilter] = [:]
    private let services: any ConfigurationServices
    private let credentials: any ConfigurationCredentials
    private let artworkPreparation: any OfflineArtworkPreparing
    private var filterTask: Task<Void, Never>?
    private var previewController: ArtworkPreviewController?
    private var folderPanel: NSOpenPanel?
    private var workspaceObserver: ConfigurationObserver?
    private var thermalObserver: ConfigurationObserver?
    private var operationTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?
    private var cacheOperationID = UUID()
    private var generation = 0
    private var initialized = false

    init(services: any ConfigurationServices = DefaultConfigurationServices(), credentials: any ConfigurationCredentials = DefaultConfigurationCredentials(), artworkPreparation: any OfflineArtworkPreparing = OfflineArtworkPreparation.forConnectedDisplays(), restoreCredentials: Bool = true) {
        self.services = services; self.credentials = credentials; self.artworkPreparation = artworkPreparation
        let settings = Preferences.settingsSnapshot()
        gridRows = settings.rows; gridColumns = settings.columns; gridAutoColumns = settings.autoColumns
        rotationInterval = settings.rotationInterval; imageSource = settings.imageSource
        artworkFraming = settings.artworkFraming; transitionDuration = settings.transitionDuration
        localFolderBookmark = Preferences.localFolderBookmark; localFolderIdentity = Preferences.localFolderIdentity
        localFolderName = localFolderBookmark.flatMap { LocalArtworkFolder.displayName(bookmarkData: $0) } ?? ""
        showTitleReveal = settings.showTitleReveal; titleDisplayDuration = settings.titleDisplayDuration
        providerType = Preferences.providerType
        plexServerURL = Preferences.plexServerURL; selectedServerURI = plexServerURL
        plexAccountID = Preferences.plexAccountID; plexServerID = Preferences.plexServerID; plexFallbackURLs = Preferences.plexFallbackURLs
        jellyfinServerURL = Preferences.jellyfinServerURL; jellyfinUsername = Preferences.jellyfinUsername
        jellyfinUserID = Preferences.jellyfinUserId
        installedJellyfinConnection = JellyfinConnectionMetadata(serverURL: jellyfinServerURL, username: jellyfinUsername, userID: jellyfinUserID)
        loadSelection(for: currentProfile)
        initialized = true
        workspaceObserver = ConfigurationObserver(center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.screensDidSleepNotification) { [weak self] _ in
            Task { @MainActor in self?.cancelArtworkPreparation(reason: "Preparation canceled while the display sleeps. Downloaded artwork was kept.") }
        }
        thermalObserver = ConfigurationObserver(center: .default, name: ProcessInfo.thermalStateDidChangeNotification) { [weak self] _ in
            Task { @MainActor in
                if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
                    self?.cancelArtworkPreparation(reason: "Preparation canceled while the Mac cools down. Downloaded artwork was kept.")
                }
            }
        }
        if restoreCredentials { restore() }
    }
    deinit {
        operationTask?.cancel(); restoreTask?.cancel(); cacheTask?.cancel(); diagnosticTask?.cancel(); filterTask?.cancel()
    }

    var currentProfile: ConnectionProfile {
        profile(for: providerType)
    }
    private func profile(for provider: ProviderType) -> ConnectionProfile {
        switch provider {
        case .plex: return ConnectionProfile(provider: .plex, serverURL: plexServerURL, accountID: plexAccountID, serverID: plexServerID)
        case .jellyfin: return ConnectionProfile(provider: .jellyfin, serverURL: jellyfinServerURL, accountID: jellyfinUserID)
        case .local: return ConnectionProfile(provider: .local, serverURL: "", accountID: localFolderIdentity)
        }
    }
    var currentSelection: LibrarySelection { allLibraries ? .all : .selected(selectedLibraryIds) }
    var currentConnection: ConnectionSnapshot {
        ConnectionSnapshot(provider: providerType, serverURL: currentProfile.serverURL,
                           token: providerType == .local ? "" : (providerType == .plex ? plexToken : jellyfinToken),
                           userID: providerType == .jellyfin ? jellyfinUserID : "", accountID: currentProfile.accountID, serverID: currentProfile.serverID, fallbackURLs: providerType == .plex ? plexFallbackURLs : [], localFolderBookmark: providerType == .local ? localFolderBookmark : nil)
    }
    private func loadSelection(for profile: ConnectionProfile) {
        mediaFilter = (profileFilters[profile] ?? Preferences.mediaFilter(for: profile)).supported(by: profile.provider.filterCapabilities)
        let selection = profileSelections[profile] ?? Preferences.librarySelection(for: profile)
        switch selection { case .all: allLibraries = true; selectedLibraryIds = []; case .selected(let ids): allLibraries = false; selectedLibraryIds = ids }
    }
    private func cancelOperations() {
        generation += 1
        operationTask?.cancel(); operationTask = nil
        restoreTask?.cancel(); restoreTask = nil
        filterTask?.cancel(); filterTask = nil
        isSigningIn = false; isJellyfinConnecting = false; isRestoring = false
        connectionState = .idle
    }
    func cancelPendingOperations() {
        let canceledPlexSignIn = isSigningIn || pendingAuthToken != nil
        let canceledJellyfinSignIn = isJellyfinConnecting
        cancelOperations(); cacheTask?.cancel(); diagnosticTask?.cancel()
        folderPanel?.cancel(nil); folderPanel = nil
        pendingAuthToken = nil; pendingPlexAccountID = nil; discoveredServers = []; jellyfinPassword = ""
        isSignedIn = !plexServerURL.isEmpty && !plexToken.isEmpty
        if canceledPlexSignIn { signInStatus = "Sign-in canceled" }
        if canceledJellyfinSignIn { jellyfinStatus = "Connection canceled" }
        cacheOperationID = UUID(); isManagingCache = false; preparationProgress = nil
    }
    private func accepts(_ id: Int, provider: ProviderType) -> Bool { id == generation && provider == providerType && !Task.isCancelled }
    private func connectionInputChanged(provider: ProviderType) {
        guard initialized, !updatesConnectionInternally else { return }
        cancelArtworkPreparation(); closeArtworkPreview()
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
        let oldProfile = profile(for: oldProvider)
        profileSelections[oldProfile] = currentSelection
        profileFilters[oldProfile] = mediaFilter
        cancelArtworkPreparation(); closeArtworkPreview(); filterOptions = MediaFilterOptions(); filterStatus = ""
        cancelOperations(); discoveredLibraries = []; jellyfinPassword = ""
        pendingAuthToken = nil; pendingPlexAccountID = nil; discoveredServers = []
        loadSelection(for: currentProfile)
        if isConnected { testConnection() } else { restore() }
    }
    func retryCredentials() { restore(allowInteraction: true) }
    private func restore(allowInteraction: Bool = false) {
        if providerType == .local { testConnection(); return }
        let keys = providerType == .plex ? ["PlexToken", "PlexAuthToken"] : ["JellyfinAccessToken"]
        guard credentialsToClear.isDisjoint(with: keys) else { return }
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
        profileFilters[currentProfile] = mediaFilter
        cancelOperations()
        if let pendingAuthToken, let pendingPlexAccountID {
            authToken = pendingAuthToken; plexAccountID = pendingPlexAccountID
            dirtyCredentials.insert("PlexAuthToken"); credentialsToClear.remove("PlexAuthToken")
            self.pendingAuthToken = nil; self.pendingPlexAccountID = nil
        }
        plexServerURL = server.uri; plexToken = server.token; selectedServerURI = server.uri
        plexServerID = server.id; plexFallbackURLs = server.connections.map(\.uri)
        dirtyCredentials.insert("PlexToken"); credentialsToClear.remove("PlexToken"); isSignedIn = true
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
        let profile = profile(for: provider)
        cacheProfilesToClear.insert(profile)
        if provider == .jellyfin { cacheProfilesToClear.insert(installedJellyfinConnection.profile) }
        cancelOperations(); cancelArtworkPreparation(); closeArtworkPreview()
        pendingAuthToken = nil; pendingPlexAccountID = nil; discoveredLibraries = []; discoveredServers = []
        let keys = provider == .plex ? ["PlexToken", "PlexAuthToken"] : ["JellyfinAccessToken"]
        credentialsToClear.formUnion(keys); dirtyCredentials.subtract(keys)
        if provider == .plex {
            plexToken = ""; authToken = ""; isSignedIn = false; plexServerURL = ""; selectedServerURI = ""
            plexAccountID = ""; plexServerID = ""; plexFallbackURLs = []
            signInStatus = "Sign-out will take effect when you apply changes."
        } else {
            jellyfinToken = ""; jellyfinUserID = ""; jellyfinPassword = ""; isJellyfinConnected = false
            stagedJellyfinConnection = nil; disconnectedJellyfin = true
            jellyfinStatus = "Disconnect will take effect when you apply changes."
        }
        storageMessage = ""
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
                dirtyCredentials.insert("JellyfinAccessToken"); credentialsToClear.remove("JellyfinAccessToken"); disconnectedJellyfin = false
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
        guard isConnected, connection.provider == .local || (!connection.serverURL.isEmpty && !connection.token.isEmpty) else { connectionState = .failed("Sign in to load your libraries"); return }
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
                refreshDiagnostics(); refreshFilterOptions()
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
        cancelPendingOperations(); closeArtworkPreview()
        isApplying = true; storageMessage = ""
        let draftProfile = currentProfile
        let staged = stagedJellyfinConnection.flatMap { connection in
            let endpoint = (try? ServerEndpoint(jellyfinServerURL).canonicalURLString) ?? jellyfinServerURL
            return endpoint == connection.metadata.serverURL && jellyfinUsername == connection.metadata.username
                && jellyfinUserID == connection.metadata.userID && jellyfinToken == connection.token ? connection : nil
        }
        let effectiveJellyfin = staged?.metadata ?? (disconnectedJellyfin
            ? JellyfinConnectionMetadata(serverURL: installedJellyfinConnection.serverURL, username: installedJellyfinConnection.username, userID: "")
            : installedJellyfinConnection)
        let profile = providerType == .jellyfin ? effectiveJellyfin.profile : currentProfile
        let sameBinding = draftProfile == profile && draftProfile.serverURL == profile.serverURL
        let selection = sameBinding ? currentSelection : (profileSelections[profile] ?? Preferences.librarySelection(for: profile))
        let pending: [String: String] = ["PlexToken": plexToken, "PlexAuthToken": authToken, "JellyfinAccessToken": staged?.token ?? ""]
        let clearKeys = credentialsToClear.sorted()
        let clearProfiles = cacheProfilesToClear
        let pendingLocalBookmark = localFolderBookmark, pendingLocalIdentity = localFolderIdentity
        let credentialKeys = dirtyCredentials.filter { $0 != "JellyfinAccessToken" || staged != nil }.sorted()
        let pendingConnections = (plexServerURL, plexAccountID, plexServerID, plexFallbackURLs,
                                  effectiveJellyfin.serverURL, effectiveJellyfin.username, effectiveJellyfin.userID, providerType)
        var filters = profileFilters
        filters[profile] = sameBinding ? mediaFilter : (profileFilters[profile] ?? Preferences.mediaFilter(for: profile))
        var selections = profileSelections
        selections[profile] = selection
        let settings = SaverSettings(rows: gridRows, columns: gridColumns, autoColumns: gridAutoColumns,
            rotationInterval: rotationInterval, imageSource: imageSource, showTitleReveal: showTitleReveal,
            titleDisplayDuration: titleDisplayDuration, librarySelection: selection, artworkFraming: artworkFraming, transitionDuration: transitionDuration, mediaFilter: filters[profile] ?? MediaFilter())
        operationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                for key in clearKeys { try await credentials.clear(key) }
                for key in credentialKeys { try await credentials.save(key, value: pending[key] ?? "") }
                Preferences.plexServerURL = pendingConnections.0; Preferences.plexAccountID = pendingConnections.1
                Preferences.plexServerID = pendingConnections.2; Preferences.plexFallbackURLs = pendingConnections.3
                Preferences.jellyfinServerURL = pendingConnections.4; Preferences.jellyfinUsername = pendingConnections.5; Preferences.jellyfinUserId = pendingConnections.6
                Preferences.providerType = pendingConnections.7
                Preferences.localFolderBookmark = pendingLocalBookmark; Preferences.localFolderIdentity = pendingLocalIdentity
                for (savedProfile, filter) in filters { Preferences.saveMediaFilter(filter, for: savedProfile) }
                for (savedProfile, selection) in selections { Preferences.saveLibrarySelection(selection, for: savedProfile) }
                Preferences.saveSettings(settings, profile: profile)
                installedJellyfinConnection = effectiveJellyfin
                stagedJellyfinConnection = nil
                updatesConnectionInternally = true
                jellyfinServerURL = effectiveJellyfin.serverURL; jellyfinUsername = effectiveJellyfin.username
                jellyfinUserID = effectiveJellyfin.userID
                updatesConnectionInternally = false
                for savedProfile in clearProfiles {
                    let cache = await DiskCacheCoordinator.shared.cache(for: savedProfile.namespace)
                    await cache.clear()
                }
                dirtyCredentials = []; credentialsToClear = []; cacheProfilesToClear = []; disconnectedJellyfin = false; isApplying = false
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
        let settings = draftSettings, dimensions = offlineDimensions(settings: settings)
        let readiness = await artworkPreparation.readiness(connection: currentConnection, settings: settings, width: dimensions.width, height: dimensions.height)
        guard !Task.isCancelled, generation == id, currentProfile == profile, currentProfile.serverURL == profile.serverURL, draftSettings == settings else { return }
        let size = ByteCountFormatter.string(fromByteCount: summary.sizeBytes, countStyle: .file)
        offlineReadiness = readiness
        cacheMessage = "\(summary.count) images · \(size)"
        diagnosticSummary = "Montage \(AppConstants.version) (\(AppConstants.build))\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nProvider: \(profile.provider.displayName)\nGrid: \(gridRows) × \(gridAutoColumns ? "auto" : String(gridColumns))\nArtwork: \(imageSource.displayName)\nCache: \(cacheMessage)\nCredential storage: Keychain; runtime interaction disabled\n"
    }
    /// Refresh does not destroy working offline images or force a memory reset.
    func refreshArtwork() { beginArtworkPreparation(refreshExisting: true) }
    func prepareForOffline() { beginArtworkPreparation(refreshExisting: false) }
    func cancelArtworkPreparation(reason: String? = nil) {
        if isManagingCache { preparationMessage = reason ?? "Preparation canceled. Downloaded artwork was kept." }
        cacheTask?.cancel(); cacheTask = nil; cacheOperationID = UUID()
        isManagingCache = false; preparationProgress = nil
    }
    func clearCache() {
        let profile = currentProfile
        cancelArtworkPreparation(); diagnosticTask?.cancel()
        let operationID = cacheOperationID
        isManagingCache = true
        cacheTask = Task { [weak self] in
            guard let self else { return }
            let cache = await DiskCacheCoordinator.shared.cache(for: profile.namespace)
            guard !Task.isCancelled, currentProfile == profile, cacheOperationID == operationID else { return }
            await cache.clear()
            guard !Task.isCancelled, currentProfile == profile, cacheOperationID == operationID else { return }
            isManagingCache = false
            NotificationCenter.default.post(name: .montageConfigChanged, object: nil)
            await readDiagnostics(profile: profile, generation: generation)
        }
    }
    private func beginArtworkPreparation(refreshExisting: Bool) {
        guard isConnected else { preparationMessage = "Connect before preparing artwork."; return }
        guard ProcessInfo.processInfo.thermalState != .serious && ProcessInfo.processInfo.thermalState != .critical else {
            preparationMessage = "Let the Mac cool down before preparing artwork."; return
        }
        cancelArtworkPreparation(); diagnosticTask?.cancel()
        let operationID = cacheOperationID
        let connection = currentConnection, settings = draftSettings
        let dimensions = offlineDimensions(settings: settings)
        isManagingCache = true; preparationMessage = "Loading selected artwork…"
        cacheTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await artworkPreparation.prepare(connection: connection, settings: settings,
                    width: dimensions.width, height: dimensions.height, refreshExisting: refreshExisting) { [weak self] progress in
                        await self?.publishPreparation(progress, operation: operationID, profile: connection.profile)
                    }
                guard !Task.isCancelled, cacheOperationID == operationID, currentProfile == connection.profile else { return }
                preparationMessage = result.message
            } catch {
                guard !Task.isCancelled, cacheOperationID == operationID, currentProfile == connection.profile else { return }
                preparationMessage = "Unable to refresh: \(error.localizedDescription). Cached artwork is still available."
            }
            guard cacheOperationID == operationID else { return }
            isManagingCache = false; preparationProgress = nil
            await readDiagnostics(profile: connection.profile, generation: generation)
        }
    }
    private func publishPreparation(_ progress: OfflineArtworkProgress, operation: UUID, profile: ConnectionProfile) {
        guard cacheOperationID == operation, currentProfile == profile, !Task.isCancelled else { return }
        preparationProgress = progress
        preparationMessage = "\(progress.completed) of \(progress.total) titles checked · \(progress.downloaded) images downloaded"
    }
    func cancel(onClose: () -> Void) {
        guard !isApplying else { return }
        cancelPendingOperations(); closeArtworkPreview()
        onClose()
    }
    var draftSettings: SaverSettings {
        SaverSettings(rows: gridRows, columns: gridColumns, autoColumns: gridAutoColumns,
            rotationInterval: rotationInterval, imageSource: imageSource, showTitleReveal: showTitleReveal,
            titleDisplayDuration: titleDisplayDuration, librarySelection: currentSelection,
            artworkFraming: artworkFraming, transitionDuration: transitionDuration, mediaFilter: mediaFilter.supported(by: providerType.filterCapabilities))
    }
    func applyPreset(_ preset: PresentationPreset) {
        let settings = draftSettings.applying(preset)
        gridRows = settings.rows; gridColumns = settings.columns; gridAutoColumns = settings.autoColumns
        imageSource = settings.imageSource; rotationInterval = settings.rotationInterval
        showTitleReveal = settings.showTitleReveal; titleDisplayDuration = settings.titleDisplayDuration
        artworkFraming = settings.artworkFraming; transitionDuration = settings.transitionDuration
        refreshDiagnostics()
    }
    func showArtworkPreview() {
        guard isConnected else { return }
        if previewController == nil { previewController = ArtworkPreviewController() }
        previewController?.show(settings: draftSettings, connection: currentConnection)
    }
    func updateArtworkPreview() { previewController?.update(settings: draftSettings, connection: currentConnection) }
    func closeArtworkPreview() { previewController?.close(); previewController = nil }
    func chooseLocalFolder() {
        guard folderPanel == nil else { folderPanel?.makeKeyAndOrderFront(nil); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Choose artwork folder"; panel.message = "Choose a folder containing JPEG, PNG, HEIC, or other supported images."
        folderPanel = panel
        let id = generation
        panel.begin { [weak self, weak panel] response in
            Task { @MainActor in
                guard let self, let panel, self.folderPanel === panel else { return }
                self.folderPanel = nil
                guard response == .OK, let url = panel.url, self.generation == id, self.providerType == .local else { return }
                self.stageLocalFolder(url)
            }
        }
    }
    func stageLocalFolder(_ url: URL) {
        do {
            let bookmark = try LocalArtworkFolder.bookmark(for: url)
            profileSelections[currentProfile] = currentSelection; profileFilters[currentProfile] = mediaFilter
            cancelOperations(); cancelArtworkPreparation(); closeArtworkPreview()
            localFolderBookmark = bookmark; localFolderIdentity = LocalArtworkFolder.identity(for: url)
            localFolderName = url.lastPathComponent; loadSelection(for: currentProfile); testConnection()
        } catch { storageMessage = error.localizedDescription }
    }
    func refreshFilterOptions() {
        filterTask?.cancel()
        let connection = currentConnection
        guard isConnected, providerType != .local else { filterOptions = MediaFilterOptions(); return }
        let libraryIds = discoveredLibraries.filter { currentSelection.includes($0.id) }.map(\.id)
        filterStatus = "Loading available filters…"
        filterTask = Task { [weak self] in
            guard let self else { return }
            do {
                let options = try await services.filterOptions(connection: connection, libraryIds: libraryIds)
                guard !Task.isCancelled, currentProfile == connection.profile else { return }
                filterOptions = options; filterStatus = ""
            } catch {
                guard !Task.isCancelled, currentProfile == connection.profile else { return }
                filterStatus = "Available filters could not be loaded. Your saved choices are preserved."
            }
        }
    }
    func genreBinding(_ genre: String) -> Binding<Bool> {
        Binding(get: { self.mediaFilter.genres.contains(genre) }, set: { selected in
            self.mediaFilter.genres.removeAll { $0 == genre }; if selected { self.mediaFilter.genres.append(genre) }
        })
    }
    func collectionBinding(_ collection: String) -> Binding<Bool> {
        Binding(get: { self.mediaFilter.collections.contains(collection) }, set: { selected in
            self.mediaFilter.collections.removeAll { $0 == collection }; if selected { self.mediaFilter.collections.append(collection) }
        })
    }
    private func offlineDimensions(settings: SaverSettings) -> (width: Int, height: Int) {
        ConfigurationDisplayDimensions.requestDimensions(settings: settings)
    }
    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticSummary, forType: .string)
    }
}


/// Foundation notification registration/removal is thread-safe. This immutable
/// owner removes its opaque token without crossing a main-actor deinit boundary.
private final class ConfigurationObserver: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol
    init(center: NotificationCenter, name: Notification.Name, handler: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: .main, using: handler)
    }
    deinit { center.removeObserver(token) }
}
