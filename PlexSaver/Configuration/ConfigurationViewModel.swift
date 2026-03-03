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
    @Published var discoveredLibraries: [PlexLibrary] = []

    // Auth state
    @Published var isSigningIn = false
    @Published var signInStatus = ""
    @Published var isSignedIn = false
    @Published var discoveredServers: [PlexServer] = []
    @Published var selectedServerURI: String = ""

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
    }

    private func setupBindings() {
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
    }

    // MARK: - Library Binding

    func libraryBinding(for key: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { self.selectedLibraryIds.contains(key) },
            set: { isSelected in
                if isSelected {
                    self.selectedLibraryIds.insert(key)
                } else {
                    self.selectedLibraryIds.remove(key)
                }
            }
        )
    }

    // MARK: - Test Connection

    func testConnection() {
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
                    self.discoveredLibraries = libraries

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
}
