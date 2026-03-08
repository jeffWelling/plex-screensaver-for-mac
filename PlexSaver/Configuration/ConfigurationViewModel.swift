//
//  ConfigurationViewModel.swift
//  PlexSaver
//

import SwiftUI
import Combine

class ConfigurationViewModel: ObservableObject {
    @Published var plexServerURL: String = ""
    @Published var plexToken: String = ""
    @Published var gridRows: Int = 3
    @Published var gridColumns: Int = 4
    @Published var rotationInterval: Double = 5.0
    @Published var imageSource: ImageSourceType = .fanart
    @Published var selectedLibraryIds: Set<String> = []
    @Published var showTitleReveal: Bool = true
    @Published var titleDisplayDuration: Double = 2.0
    @Published var discoveredLibraries: [MediaLibrary] = []

    // Provider selection
    @Published var providerType: ProviderType = .plex

    // Plex auth state
    @Published var isSigningIn = false
    @Published var signInStatus = ""
    @Published var isSignedIn = false
    @Published var discoveredServers: [PlexServer] = []
    @Published var selectedServerURI: String = ""

    // Jellyfin
    @Published var jellyfinServerURL: String = ""
    @Published var jellyfinUsername: String = ""
    @Published var jellyfinPassword: String = ""  // Not persisted — cleared after auth
    @Published var isJellyfinConnected: Bool = false
    @Published var isJellyfinConnecting: Bool = false
    @Published var jellyfinStatus: String = ""

    // Connection test state
    @Published var isTesting = false
    @Published var testResult: Bool?
    @Published var testMessage = ""

    private var cancellables = Set<AnyCancellable>()
    private var authToken: String = "" // plex.tv account token (for server discovery)

    init() {
        loadPreferences()
        setupBindings()
        // If we already have a server configured, mark as signed in
        if !plexServerURL.isEmpty && !plexToken.isEmpty {
            isSignedIn = true
            selectedServerURI = plexServerURL
        }
        // Restore persisted auth token for server re-discovery
        authToken = Preferences.plexAuthToken
    }

    // MARK: - Plex OAuth Sign-In

    func signInWithPlex() {
        isSigningIn = true
        signInStatus = "Opening browser..."

        Task {
            do {
                let auth = PlexAuth()

                // Step 1: Create PIN
                let pin = try await auth.createPin()

                // Step 2: Open browser
                guard let url = await auth.authURL(for: pin) else {
                    throw PlexAuthError.invalidURL
                }

                await MainActor.run {
                    NSWorkspace.shared.open(url)
                    self.signInStatus = "Waiting for you to sign in..."
                }

                // Step 3: Poll for token
                let token = try await auth.pollForToken(pinId: pin.id, code: pin.code)
                self.authToken = token
                Preferences.plexAuthToken = token

                await MainActor.run {
                    self.signInStatus = "Discovering servers..."
                }

                // Step 4: Discover servers
                let servers = try await auth.discoverServers(authToken: token)

                await MainActor.run {
                    self.isSigningIn = false
                    self.discoveredServers = servers

                    if servers.isEmpty {
                        self.signInStatus = "No servers found"
                    } else if servers.count == 1 {
                        // Auto-select the only server
                        self.selectServer(servers[0])
                    } else {
                        self.signInStatus = "Select a server"
                    }
                }
            } catch {
                await MainActor.run {
                    self.isSigningIn = false
                    self.signInStatus = error.localizedDescription
                }
            }
        }
    }

    func selectServer(_ server: PlexServer) {
        plexServerURL = server.uri
        plexToken = server.token
        selectedServerURI = server.uri
        isSignedIn = true
        signInStatus = "Connected to \(server.name)"

        // Auto-test and discover libraries
        testConnection()
    }

    func changeServer() {
        guard !authToken.isEmpty else {
            // No auth token stored — need to sign in again
            signOut()
            return
        }

        isSignedIn = false
        isSigningIn = true
        signInStatus = "Discovering servers..."
        discoveredLibraries = []
        testResult = nil
        testMessage = ""

        Task {
            do {
                let auth = PlexAuth()
                let servers = try await auth.discoverServers(authToken: authToken)

                await MainActor.run {
                    self.isSigningIn = false
                    self.discoveredServers = servers

                    if servers.isEmpty {
                        self.signInStatus = "No servers found"
                    } else {
                        self.signInStatus = "Select a server"
                    }
                }
            } catch {
                await MainActor.run {
                    self.isSigningIn = false
                    self.signInStatus = "Failed to discover servers — try signing out and back in"
                }
            }
        }
    }

    func signOut() {
        plexServerURL = ""
        plexToken = ""
        selectedServerURI = ""
        isSignedIn = false
        discoveredServers = []
        discoveredLibraries = []
        selectedLibraryIds = []
        signInStatus = ""
        testResult = nil
        testMessage = ""
        authToken = ""
        Preferences.plexAuthToken = ""
    }

    // MARK: - Load/Save

    private func loadPreferences() {
        plexServerURL = Preferences.plexServerURL
        plexToken = Preferences.plexToken
        gridRows = Preferences.gridRows
        gridColumns = Preferences.gridColumns
        rotationInterval = Preferences.rotationInterval
        imageSource = Preferences.imageSource
        selectedLibraryIds = Set(Preferences.selectedLibraryIds)
        showTitleReveal = Preferences.showTitleReveal
        titleDisplayDuration = Preferences.titleDisplayDuration
        providerType = Preferences.providerType
        jellyfinServerURL = Preferences.jellyfinServerURL
        jellyfinUsername = Preferences.jellyfinUsername
        isJellyfinConnected = !Preferences.jellyfinAccessToken.isEmpty
    }

    private func setupBindings() {
        $providerType
            .dropFirst()
            .sink { Preferences.providerType = $0 }
            .store(in: &cancellables)

        $plexServerURL
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { Preferences.plexServerURL = $0 }
            .store(in: &cancellables)

        $plexToken
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { Preferences.plexToken = $0 }
            .store(in: &cancellables)

        $gridRows
            .sink { Preferences.gridRows = $0 }
            .store(in: &cancellables)

        $gridColumns
            .sink { Preferences.gridColumns = $0 }
            .store(in: &cancellables)

        $rotationInterval
            .sink { Preferences.rotationInterval = $0 }
            .store(in: &cancellables)

        $imageSource
            .sink { Preferences.imageSource = $0 }
            .store(in: &cancellables)

        $selectedLibraryIds
            .sink { Preferences.selectedLibraryIds = Array($0) }
            .store(in: &cancellables)

        $showTitleReveal
            .sink { Preferences.showTitleReveal = $0 }
            .store(in: &cancellables)

        $titleDisplayDuration
            .sink { Preferences.titleDisplayDuration = $0 }
            .store(in: &cancellables)
    }

    // MARK: - Library Binding

    func libraryBinding(for id: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { self.selectedLibraryIds.contains(id) },
            set: { isSelected in
                if isSelected {
                    self.selectedLibraryIds.insert(id)
                } else {
                    self.selectedLibraryIds.remove(id)
                }
            }
        )
    }

    // MARK: - Test Connection

    func testConnection() {
        switch providerType {
        case .plex:
            testPlexConnection()
        case .jellyfin:
            testJellyfinConnection()
        }
    }

    private func testPlexConnection() {
        guard !plexServerURL.isEmpty, !plexToken.isEmpty else { return }

        isTesting = true
        testResult = nil
        testMessage = ""

        let client = PlexClient(serverURL: plexServerURL, token: plexToken)

        Task {
            do {
                let libraries = try await client.fetchLibraries()
                await MainActor.run {
                    self.isTesting = false
                    self.testResult = true
                    self.testMessage = "\(libraries.count) libraries found"
                    self.discoveredLibraries = libraries.map { $0.toMediaLibrary() }

                    if self.selectedLibraryIds.isEmpty {
                        self.selectedLibraryIds = Set(libraries.map { $0.key })
                    }
                }
            } catch {
                await MainActor.run {
                    self.isTesting = false
                    self.testResult = false
                    self.testMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Jellyfin Connection

    func connectToJellyfin() {
        guard !jellyfinServerURL.isEmpty, !jellyfinUsername.isEmpty, !jellyfinPassword.isEmpty else {
            jellyfinStatus = "Please fill in all fields"
            return
        }

        isJellyfinConnecting = true
        jellyfinStatus = "Connecting..."

        Task {
            do {
                let auth = JellyfinAuth()
                let result = try await auth.authenticate(
                    serverURL: jellyfinServerURL,
                    username: jellyfinUsername,
                    password: jellyfinPassword
                )

                await MainActor.run {
                    Preferences.jellyfinServerURL = jellyfinServerURL
                    Preferences.jellyfinUsername = jellyfinUsername
                    Preferences.jellyfinAccessToken = result.accessToken
                    Preferences.jellyfinUserId = result.userId
                    isJellyfinConnected = true
                    isJellyfinConnecting = false
                    jellyfinStatus = "Connected"
                    jellyfinPassword = ""  // Clear password from memory
                    testJellyfinConnection()
                }
            } catch {
                await MainActor.run {
                    isJellyfinConnecting = false
                    jellyfinStatus = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func disconnectJellyfin() {
        Preferences.jellyfinAccessToken = ""
        Preferences.jellyfinUserId = ""
        isJellyfinConnected = false
        jellyfinStatus = ""
        discoveredLibraries = []
    }

    func testJellyfinConnection() {
        let serverURL = Preferences.jellyfinServerURL
        let token = Preferences.jellyfinAccessToken
        let userId = Preferences.jellyfinUserId

        guard !serverURL.isEmpty, !token.isEmpty, !userId.isEmpty else { return }

        isTesting = true
        testResult = nil
        testMessage = ""

        Task {
            do {
                let provider = JellyfinProvider(serverURL: serverURL, accessToken: token, userId: userId)
                let libraries = try await provider.fetchLibraries()

                await MainActor.run {
                    discoveredLibraries = libraries
                    isTesting = false
                    testResult = true
                    testMessage = "Connected — \(libraries.count) libraries found"

                    if selectedLibraryIds.isEmpty {
                        selectedLibraryIds = Set(libraries.map { $0.id })
                    }
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testResult = false
                    testMessage = error.localizedDescription
                }
            }
        }
    }
}
