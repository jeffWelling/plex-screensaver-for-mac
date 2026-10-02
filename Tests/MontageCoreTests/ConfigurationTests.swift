import XCTest
import Security
@testable import MontageCore

private actor SuspendedConfigurationServices: ConfigurationServices {
    private let servers: [PlexServer]
    private let suspendLibraries: Bool
    private let libraryFixtures: [MediaLibrary]
    init(servers: [PlexServer] = [], suspendLibraries: Bool = true, libraryFixtures: [MediaLibrary] = []) { self.servers = servers; self.suspendLibraries = suspendLibraries; self.libraryFixtures = libraryFixtures }
    var auth: CheckedContinuation<String, Error>?
    var libraryRequest: CheckedContinuation<[MediaLibrary], Error>?
    var authStarted: Bool { auth != nil }
    var librariesStarted: Bool { libraryRequest != nil }
    func plexSignIn(status: @escaping @Sendable (String) async -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { auth = $0 }
    }
    func finishAuth() { auth?.resume(returning: "late-token"); auth = nil }
    func plexAccountID(token: String) async throws -> String { "42" }
    func plexServers(token: String) async throws -> [PlexServer] { servers }
    func libraries(connection: ConnectionSnapshot) async throws -> [MediaLibrary] {
        if !suspendLibraries { return libraryFixtures }
        return try await withCheckedThrowingContinuation { libraryRequest = $0 }
    }
    func finishLibraries() { libraryRequest?.resume(returning: [MediaLibrary(id: "old", name: "Old account library", type: "movies")]); libraryRequest = nil }
    func jellyfinSignIn(serverURL: String, username: String, password: String) async throws -> (accessToken: String, userId: String) { ("token", "user") }
}
private struct FakeConfigurationCredentials: ConfigurationCredentials {
    var failSave = false
    func read(_ key: String, allowInteraction: Bool) async throws -> String { "" }
    func save(_ key: String, value: String) async throws {
        if failSave { throw CredentialStorageError(operation: .save, status: errSecAuthFailed) }
    }
    func clear(_ key: String) async throws {}
}

private actor RecordingConfigurationCredentials: ConfigurationCredentials {
    private(set) var saved: [String] = []
    func read(_ key: String, allowInteraction: Bool) async throws -> String { "" }
    func save(_ key: String, value: String) async throws { saved.append(key) }
    func clear(_ key: String) async throws {}
}

private struct FixedRestoreCredentials: ConfigurationCredentials {
    let accountToken: String
    func read(_ key: String, allowInteraction: Bool) async throws -> String { key == "PlexAuthToken" ? accountToken : "existing-server-token" }
    func save(_ key: String, value: String) async throws {}
    func clear(_ key: String) async throws {}
}

private actor ImmediateJellyfinServices: ConfigurationServices {
    private(set) var requests: [ConnectionSnapshot] = []
    func plexSignIn(status: @escaping @Sendable (String) async -> Void) async throws -> String { "" }
    func plexAccountID(token: String) async throws -> String { "42" }
    func plexServers(token: String) async throws -> [PlexServer] { [] }
    func libraries(connection: ConnectionSnapshot) async throws -> [MediaLibrary] { requests.append(connection); return [] }
    func jellyfinSignIn(serverURL: String, username: String, password: String) async throws -> (accessToken: String, userId: String) { ("staged-A-token", "staged-A-user") }
}

private actor SuspendedRestoreCredentials: ConfigurationCredentials {
    private var continuation: CheckedContinuation<String, Error>?
    var started: Bool { continuation != nil }
    func read(_ key: String, allowInteraction: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: "account-A-token"); continuation = nil }
    func save(_ key: String, value: String) async throws {}
    func clear(_ key: String) async throws {}
}
private actor RecordingRestoreServices: ConfigurationServices {
    private(set) var libraryRequests: [ConnectionSnapshot] = []
    func plexSignIn(status: @escaping @Sendable (String) async -> Void) async throws -> String { "" }
    func plexAccountID(token: String) async throws -> String { "42" }
    func plexServers(token: String) async throws -> [PlexServer] { [] }
    func libraries(connection: ConnectionSnapshot) async throws -> [MediaLibrary] { libraryRequests.append(connection); return [] }
    func jellyfinSignIn(serverURL: String, username: String, password: String) async throws -> (accessToken: String, userId: String) { ("", "") }
}

@MainActor final class ConfigurationTests: XCTestCase {
    func testEditedDraftAfterStagedJellyfinAuthenticationCannotPersistTokenToDifferentServer() async throws {
        let previous = (Preferences.providerType, Preferences.jellyfinServerURL, Preferences.jellyfinUsername, Preferences.jellyfinUserId)
        defer {
            Preferences.providerType = previous.0; Preferences.jellyfinServerURL = previous.1
            Preferences.jellyfinUsername = previous.2; Preferences.jellyfinUserId = previous.3
        }
        Preferences.providerType = .jellyfin; Preferences.jellyfinServerURL = "https://installed.invalid"
        Preferences.jellyfinUsername = "Installed"; Preferences.jellyfinUserId = "installed-user"
        let services = ImmediateJellyfinServices()
        let credentials = RecordingConfigurationCredentials()
        let viewModel = ConfigurationViewModel(services: services, credentials: credentials, restoreCredentials: false)
        viewModel.jellyfinServerURL = "https://staged-A.invalid"; viewModel.jellyfinUsername = "StagedAlice"
        viewModel.jellyfinPassword = "test-password"
        viewModel.connectToJellyfin()
        for _ in 0..<100 where viewModel.isJellyfinConnecting { await Task.yield() }
        XCTAssertTrue(viewModel.isJellyfinConnected)
        viewModel.jellyfinServerURL = "https://server-B.invalid"
        XCTAssertFalse(viewModel.isJellyfinConnected)
        viewModel.testConnection()
        var closed = false
        viewModel.apply { closed = true }
        for _ in 0..<100 where !closed { await Task.yield() }
        XCTAssertTrue(closed)
        XCTAssertEqual(Preferences.jellyfinServerURL, "https://installed.invalid")
        XCTAssertEqual(Preferences.jellyfinUsername, "Installed")
        XCTAssertEqual(Preferences.jellyfinUserId, "installed-user")
        let saved = await credentials.saved
        XCTAssertFalse(saved.contains("JellyfinAccessToken"))
        let requests = await services.requests
        XCTAssertFalse(requests.contains { $0.serverURL.lowercased().contains("server-b") })
        let snapshot = try await Preferences.connectionSnapshot { _ in "installed-token" }
        XCTAssertEqual(snapshot.serverURL, "https://installed.invalid")
        XCTAssertEqual(snapshot.userID, "installed-user")
        viewModel.cancelPendingOperations()
    }
    func testVerifiedLegacyTokenMigrationCarriesItsLibrarySelectionToStableUserID() async {
        let previous = (Preferences.providerType, Preferences.plexServerURL, Preferences.plexAccountID, Preferences.plexServerID)
        Preferences.providerType = .plex; Preferences.plexServerURL = "https://migration.invalid"
        Preferences.plexAccountID = Preferences.legacyPlexAccountIdentifier(for: "verified-account-token")
        Preferences.plexServerID = UUID().uuidString
        let original = Preferences.connectionProfile
        Preferences.saveLibrarySelection(.selected(["latest"]), for: original)
        let services = SuspendedConfigurationServices(suspendLibraries: false, libraryFixtures: [MediaLibrary(id: "latest", name: "Latest", type: "movies")])
        let viewModel = ConfigurationViewModel(services: services, credentials: FixedRestoreCredentials(accountToken: "verified-account-token"))
        defer {
            Preferences.defaults.removeObject(forKey: "LibrarySelection.\(original.namespace)")
            Preferences.defaults.removeObject(forKey: "LibrarySelection.\(viewModel.currentProfile.namespace)")
            Preferences.providerType = previous.0; Preferences.plexServerURL = previous.1
            Preferences.plexAccountID = previous.2; Preferences.plexServerID = previous.3
        }
        for _ in 0..<100 where viewModel.isRestoring { await Task.yield() }
        XCTAssertFalse(viewModel.isRestoring)
        XCTAssertEqual(viewModel.currentProfile.accountID, "42")
        XCTAssertFalse(viewModel.allLibraries)
        XCTAssertEqual(viewModel.selectedLibraryIds, ["latest"])
        var closed = false
        viewModel.apply { closed = true }
        for _ in 0..<100 where !closed { await Task.yield() }
        XCTAssertTrue(closed)
        XCTAssertEqual(Preferences.librarySelection(for: viewModel.currentProfile), .selected(["latest"]))
        viewModel.cancelPendingOperations()
    }
    func testLegacyIdentityFromDifferentTokenDoesNotTransferLibrarySelection() async {
        let previous = (Preferences.providerType, Preferences.plexServerURL, Preferences.plexAccountID, Preferences.plexServerID)
        Preferences.providerType = .plex; Preferences.plexServerURL = "https://migration.invalid"
        Preferences.plexAccountID = Preferences.legacyPlexAccountIdentifier(for: "different-account-token")
        Preferences.plexServerID = UUID().uuidString
        let original = Preferences.connectionProfile
        Preferences.saveLibrarySelection(.selected(["old-account-only"]), for: original)
        let viewModel = ConfigurationViewModel(services: SuspendedConfigurationServices(suspendLibraries: false), credentials: FixedRestoreCredentials(accountToken: "verified-account-token"))
        defer {
            Preferences.defaults.removeObject(forKey: "LibrarySelection.\(original.namespace)")
            Preferences.defaults.removeObject(forKey: "LibrarySelection.\(viewModel.currentProfile.namespace)")
            Preferences.providerType = previous.0; Preferences.plexServerURL = previous.1
            Preferences.plexAccountID = previous.2; Preferences.plexServerID = previous.3
        }
        for _ in 0..<100 where viewModel.isRestoring { await Task.yield() }
        XCTAssertEqual(viewModel.currentProfile.accountID, "42")
        XCTAssertTrue(viewModel.allLibraries)
        XCTAssertTrue(viewModel.selectedLibraryIds.isEmpty)
        viewModel.cancelPendingOperations()
    }
    func testReauthenticationOfSameStableUserRetainsExplicitEmptyLibraryChoice() async {
        let previous = (Preferences.providerType, Preferences.plexServerURL, Preferences.plexAccountID, Preferences.plexServerID)
        Preferences.providerType = .plex; Preferences.plexServerURL = "https://same-user.invalid"
        Preferences.plexAccountID = "42"; Preferences.plexServerID = UUID().uuidString
        let original = Preferences.connectionProfile
        Preferences.saveLibrarySelection(.selected([]), for: original)
        let server = PlexServer(name: "Same server", uri: original.serverURL, token: "rotated-server-token", isLocal: false, id: original.serverID)
        let services = SuspendedConfigurationServices(servers: [server], suspendLibraries: false)
        let viewModel = ConfigurationViewModel(services: services, credentials: RecordingConfigurationCredentials(), restoreCredentials: false)
        defer {
            Preferences.defaults.removeObject(forKey: "LibrarySelection.\(original.namespace)")
            Preferences.providerType = previous.0; Preferences.plexServerURL = previous.1
            Preferences.plexAccountID = previous.2; Preferences.plexServerID = previous.3
        }
        viewModel.plexToken = "previous-server-token"; viewModel.isSignedIn = true
        viewModel.signInWithPlex()
        for _ in 0..<100 where !(await services.authStarted) { await Task.yield() }
        await services.finishAuth()
        for _ in 0..<100 where viewModel.isSigningIn { await Task.yield() }
        XCTAssertEqual(viewModel.currentProfile.accountID, "42")
        XCTAssertFalse(viewModel.allLibraries)
        XCTAssertTrue(viewModel.selectedLibraryIds.isEmpty)
        var closed = false
        viewModel.apply { closed = true }
        for _ in 0..<100 where !closed { await Task.yield() }
        XCTAssertTrue(closed)
        XCTAssertEqual(Preferences.librarySelection(for: viewModel.currentProfile), .selected([]))
        viewModel.cancelPendingOperations()
    }
    func testEndpointChangeAndProviderSwitchKeepLatestPhysicalServerLibraryChoice() async {
        let previous = (Preferences.providerType, Preferences.plexServerURL, Preferences.plexAccountID,
                        Preferences.plexServerID, Preferences.plexFallbackURLs)
        Preferences.providerType = .plex
        let physicalID = UUID().uuidString
        let services = SuspendedConfigurationServices(suspendLibraries: false, libraryFixtures: [
            MediaLibrary(id: "first", name: "First", type: "movies"),
            MediaLibrary(id: "latest", name: "Latest", type: "movies")])
        let viewModel = ConfigurationViewModel(services: services, credentials: RecordingConfigurationCredentials(), restoreCredentials: false)
        defer {
            Preferences.defaults.removeObject(forKey: "LibrarySelection.\(viewModel.currentProfile.namespace)")
            Preferences.providerType = previous.0; Preferences.plexServerURL = previous.1
            Preferences.plexAccountID = previous.2; Preferences.plexServerID = previous.3; Preferences.plexFallbackURLs = previous.4
        }
        viewModel.selectServer(PlexServer(name: "Same", uri: "https://endpoint-A.invalid", token: "A", isLocal: false, id: physicalID))
        viewModel.allLibraries = false; viewModel.selectedLibraryIds = ["first"]
        viewModel.selectServer(PlexServer(name: "Same", uri: "https://endpoint-B.invalid", token: "B", isLocal: false, id: physicalID))
        viewModel.allLibraries = false; viewModel.selectedLibraryIds = ["latest"]
        viewModel.providerType = .jellyfin
        viewModel.providerType = .plex
        var closed = false
        viewModel.apply { closed = true }
        for _ in 0..<100 where !closed { await Task.yield() }
        XCTAssertTrue(closed)
        XCTAssertEqual(Preferences.librarySelection(for: viewModel.currentProfile), .selected(["latest"]))
        XCTAssertEqual(viewModel.plexServerURL, "https://endpoint-B.invalid")
        viewModel.cancelPendingOperations()
    }
    func testEditingServerDuringRestoreNeverSendsSavedTokenToEditedServer() async {
        let previous = (Preferences.providerType, Preferences.jellyfinServerURL, Preferences.jellyfinUsername, Preferences.jellyfinUserId)
        defer {
            Preferences.providerType = previous.0; Preferences.jellyfinServerURL = previous.1
            Preferences.jellyfinUsername = previous.2; Preferences.jellyfinUserId = previous.3
        }
        Preferences.providerType = .jellyfin
        Preferences.jellyfinServerURL = "https://server-A.invalid"
        Preferences.jellyfinUsername = "Alice"; Preferences.jellyfinUserId = "account-A"
        let credentials = SuspendedRestoreCredentials()
        let services = RecordingRestoreServices()
        let viewModel = ConfigurationViewModel(services: services, credentials: credentials)
        for _ in 0..<100 where !(await credentials.started) { await Task.yield() }
        let started = await credentials.started
        XCTAssertTrue(started)
        XCTAssertTrue(viewModel.isRestoring)
        viewModel.jellyfinServerURL = "https://server-B.invalid"
        viewModel.jellyfinUsername = "Bob"
        XCTAssertFalse(viewModel.isRestoring)
        await credentials.finish()
        for _ in 0..<20 { await Task.yield() }
        viewModel.testConnection()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(viewModel.isJellyfinConnected)
        XCTAssertEqual(viewModel.jellyfinServerURL, "https://server-B.invalid")
        let requests = await services.libraryRequests
        XCTAssertTrue(requests.isEmpty, "Saved account A credentials must never be sent to edited server B")
        var closed = false
        viewModel.apply { closed = true }
        for _ in 0..<100 where !closed { await Task.yield() }
        XCTAssertTrue(closed)
        XCTAssertEqual(Preferences.jellyfinServerURL, "https://server-A.invalid")
        XCTAssertEqual(Preferences.jellyfinUsername, "Alice")
        XCTAssertEqual(Preferences.jellyfinUserId, "account-A")
        do {
            let snapshot = try await Preferences.connectionSnapshot { _ in "account-A-token" }
            XCTAssertEqual(snapshot.serverURL, "https://server-a.invalid")
            XCTAssertEqual(snapshot.userID, "account-A")
        } catch { XCTFail("Preserved installed connection should remain readable: \(error)") }
        viewModel.cancelPendingOperations()
    }
    func testCloseDuringAuthenticationCancelsPromptAndPreservesExistingConnection() async {
        let services = SuspendedConfigurationServices(suspendLibraries: false)
        let credentials = RecordingConfigurationCredentials()
        let viewModel = ConfigurationViewModel(services: services, credentials: credentials, restoreCredentials: false)
        viewModel.plexServerURL = "https://existing.invalid"; viewModel.plexToken = "existing-token"; viewModel.isSignedIn = true
        viewModel.signInWithPlex()
        for _ in 0..<100 where !(await services.authStarted) { await Task.yield() }
        var closed = false
        viewModel.apply { closed = true }
        for _ in 0..<100 where !closed { await Task.yield() }
        XCTAssertTrue(closed)
        XCTAssertFalse(viewModel.isSigningIn)
        XCTAssertEqual(viewModel.plexServerURL, "https://existing.invalid")
        XCTAssertEqual(viewModel.plexToken, "existing-token")
        let saved = await credentials.saved
        XCTAssertTrue(saved.isEmpty)
        await services.finishAuth()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(viewModel.authToken.isEmpty)
        XCTAssertTrue(viewModel.discoveredServers.isEmpty)
        viewModel.cancelPendingOperations()
    }
    func testClosingUnselectedNewAccountDoesNotSavePartialCredentials() async {
        let servers = [PlexServer(name: "One", uri: "https://one.invalid", token: "one", isLocal: false),
                       PlexServer(name: "Two", uri: "https://two.invalid", token: "two", isLocal: false)]
        let services = SuspendedConfigurationServices(servers: servers, suspendLibraries: false)
        let credentials = RecordingConfigurationCredentials()
        let viewModel = ConfigurationViewModel(services: services, credentials: credentials, restoreCredentials: false)
        viewModel.plexServerURL = "https://existing.invalid"; viewModel.plexToken = "existing-token"; viewModel.isSignedIn = true
        viewModel.signInWithPlex()
        for _ in 0..<100 where !(await services.authStarted) { await Task.yield() }
        await services.finishAuth()
        for _ in 0..<100 where viewModel.isSigningIn { await Task.yield() }
        XCTAssertEqual(viewModel.discoveredServers.count, 2)
        XCTAssertTrue(viewModel.authToken.isEmpty)
        var closed = false
        viewModel.apply { closed = true }
        for _ in 0..<100 where !closed { await Task.yield() }
        XCTAssertTrue(closed)
        XCTAssertEqual(viewModel.plexServerURL, "https://existing.invalid")
        XCTAssertEqual(viewModel.plexToken, "existing-token")
        let saved = await credentials.saved
        XCTAssertTrue(saved.isEmpty)
        viewModel.cancelPendingOperations()
    }
    func testCompletedServerSelectionSavesMatchingAccountAndServerTokens() async {
        let servers = [PlexServer(name: "One", uri: "https://one.invalid", token: "one", isLocal: false),
                       PlexServer(name: "Two", uri: "https://two.invalid", token: "two", isLocal: false)]
        let services = SuspendedConfigurationServices(servers: servers, suspendLibraries: false)
        let credentials = RecordingConfigurationCredentials()
        let viewModel = ConfigurationViewModel(services: services, credentials: credentials, restoreCredentials: false)
        viewModel.signInWithPlex()
        for _ in 0..<100 where !(await services.authStarted) { await Task.yield() }
        await services.finishAuth()
        for _ in 0..<100 where viewModel.isSigningIn { await Task.yield() }
        viewModel.selectServer(servers[1])
        XCTAssertEqual(viewModel.authToken, "late-token")
        XCTAssertEqual(viewModel.plexToken, "two")
        var closed = false
        viewModel.apply { closed = true }
        for _ in 0..<100 where !closed { await Task.yield() }
        XCTAssertTrue(closed)
        let saved = await credentials.saved
        XCTAssertEqual(Set(saved), ["PlexAuthToken", "PlexToken"])
        viewModel.cancelPendingOperations()
    }
    func testProviderSwitchRejectsLateAuthentication() async {
        let services = SuspendedConfigurationServices()
        let viewModel = ConfigurationViewModel(services: services, credentials: FakeConfigurationCredentials(), restoreCredentials: false)
        viewModel.signInWithPlex()
        for _ in 0..<100 where !(await services.authStarted) { await Task.yield() }
        let authStarted = await services.authStarted
        XCTAssertTrue(authStarted)
        viewModel.providerType = .jellyfin
        await services.finishAuth()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(viewModel.authToken.isEmpty)
        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertTrue(viewModel.discoveredServers.isEmpty)
        viewModel.cancelPendingOperations()
    }
    func testSignOutRejectsLateAuthentication() async {
        let services = SuspendedConfigurationServices()
        let viewModel = ConfigurationViewModel(services: services, credentials: FakeConfigurationCredentials(), restoreCredentials: false)
        viewModel.signInWithPlex()
        for _ in 0..<100 where !(await services.authStarted) { await Task.yield() }
        let started = await services.authStarted
        XCTAssertTrue(started)
        viewModel.signOut()
        await services.finishAuth()
        for _ in 0..<100 where viewModel.isApplying { await Task.yield() }
        XCTAssertTrue(viewModel.authToken.isEmpty)
        XCTAssertFalse(viewModel.isSignedIn)
        XCTAssertTrue(viewModel.discoveredServers.isEmpty)
        viewModel.cancelPendingOperations()
    }
    func testOpeningOptionsDoesNotRewritePersistedValues() {
        let before = NSDictionary(dictionary: Preferences.defaults.dictionaryRepresentation())
        let viewModel = ConfigurationViewModel(credentials: FakeConfigurationCredentials(), restoreCredentials: false)
        let after = NSDictionary(dictionary: Preferences.defaults.dictionaryRepresentation())
        XCTAssertEqual(before, after)
        viewModel.cancelPendingOperations()
    }
    func testProviderSwitchRejectsLateLibraries() async {
        let services = SuspendedConfigurationServices()
        let viewModel = ConfigurationViewModel(services: services, credentials: FakeConfigurationCredentials(), restoreCredentials: false)
        viewModel.plexServerURL = "https://example.com"; viewModel.plexToken = "test-token"; viewModel.isSignedIn = true
        viewModel.testConnection()
        for _ in 0..<100 where !(await services.librariesStarted) { await Task.yield() }
        let librariesStarted = await services.librariesStarted
        XCTAssertTrue(librariesStarted)
        viewModel.providerType = .jellyfin
        await services.finishLibraries()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(viewModel.discoveredLibraries.isEmpty)
        XCTAssertNotEqual(viewModel.connectionState, .connected(1))
        viewModel.cancelPendingOperations()
    }
    func testUncheckingEveryLibraryProducesExplicitEmptySelection() {
        let viewModel = ConfigurationViewModel(credentials: FakeConfigurationCredentials(), restoreCredentials: false)
        viewModel.discoveredLibraries = [MediaLibrary(id: "a", name: "A", type: "movies"), MediaLibrary(id: "b", name: "B", type: "movies")]
        viewModel.allLibraries = true
        viewModel.libraryBinding(for: "a").wrappedValue = false
        viewModel.libraryBinding(for: "b").wrappedValue = false
        XCTAssertFalse(viewModel.allLibraries)
        XCTAssertTrue(viewModel.selectedLibraryIds.isEmpty)
    }
    func testStorageFailureKeepsOptionsOpenAndReportsActionableError() async {
        let services = SuspendedConfigurationServices()
        let viewModel = ConfigurationViewModel(services: services, credentials: FakeConfigurationCredentials(failSave: true), restoreCredentials: false)
        viewModel.selectServer(PlexServer(name: "Test", uri: "https://example.com", token: "test-token", isLocal: false))
        var dismissed = false
        viewModel.apply { dismissed = true }
        for _ in 0..<100 where viewModel.isApplying { await Task.yield() }
        XCTAssertFalse(dismissed)
        XCTAssertFalse(viewModel.isApplying)
        XCTAssertTrue(viewModel.storageMessage.contains("Keychain"))
        if await services.librariesStarted { await services.finishLibraries() }
        viewModel.cancelPendingOperations()
    }
}
