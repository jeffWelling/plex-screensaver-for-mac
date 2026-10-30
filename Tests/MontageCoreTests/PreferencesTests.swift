import XCTest
import Security
@testable import MontageCore

private final class MemorySecrets: SecretStoring, @unchecked Sendable {
    var values: [String: String] = [:]
    var failWrite = false
    var failDelete = false
    var mismatchReadAfterWrite = false
    func read(_ key: String, allowInteraction: Bool) throws -> String? { values[key] }
    func write(_ key: String, value: String) throws {
        if failWrite { throw CredentialStorageError(operation: .save, status: errSecAuthFailed) }
        if !mismatchReadAfterWrite { values[key] = value }
    }
    func remove(_ key: String) throws {
        if failDelete { throw CredentialStorageError(operation: .remove, status: errSecAuthFailed) }
        values.removeValue(forKey: key)
    }
}

private actor DeferredSnapshotToken {
    private var continuation: CheckedContinuation<String, Error>?
    var started: Bool { continuation != nil }
    func read(_ key: String) async throws -> String { try await withCheckedThrowingContinuation { continuation = $0 } }
    func finish() { continuation?.resume(returning: "old-server-token"); continuation = nil }
}

final class PreferencesTests: XCTestCase {
    func testRuntimeSnapshotReloadsEndpointWrittenByAnotherProcess() async throws {
        // Never let this process-based check write the installed saver's domain.
        XCTAssertTrue(AppConstants.module.hasPrefix(AppConstants.productionModule + ".tests."))
        guard AppConstants.module.hasPrefix(AppConstants.productionModule + ".tests.") else { return }
        let previousProvider = Preferences.providerType
        let previousURL = Preferences.defaults.object(forKey: "PlexServerURL")
        defer {
            Preferences.providerType = previousProvider
            if let previousURL { Preferences.defaults.set(previousURL, forKey: "PlexServerURL") }
            else { Preferences.defaults.removeObject(forKey: "PlexServerURL") }
            Preferences.defaults.synchronize()
        }
        Preferences.providerType = .plex
        Preferences.plexServerURL = "https://old-plex-dns.invalid:32400"
        Preferences.defaults.synchronize()
        XCTAssertEqual(Preferences.plexServerURL, "https://old-plex-dns.invalid:32400")

        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        writer.arguments = ["-currentHost", "write", AppConstants.module, "PlexServerURL", "-string", "http://10.1.2.3:32400"]
        try writer.run()
        writer.waitUntilExit()
        XCTAssertEqual(writer.terminationStatus, 0)

        let snapshot = try await Preferences.connectionSnapshot { _ in "fixture-token" }
        XCTAssertEqual(snapshot.serverURL, "http://10.1.2.3:32400")
        XCTAssertEqual(snapshot.token, "fixture-token")
    }

    @MainActor
    func testConfigurationSignalReceivesOtherHostsButIgnoresOwnAndOtherDomains() {
        let center = NotificationCenter()
        let changed = expectation(description: "one external configuration signal")
        changed.assertForOverFulfill = true
        let observation = ConfigurationChangeObservation(center: center) { changed.fulfill() }
        withExtendedLifetime(observation) {
            center.post(name: Preferences.distributedChangeNotification, object: Preferences.changeNotificationSender)
            center.post(name: Notification.Name("other.module.configurationChanged"), object: "another-host")
            center.post(name: Preferences.distributedChangeNotification, object: "another-host")
            wait(for: [changed], timeout: 1)
        }
    }

    private func withRepository(_ body: (CredentialRepository, MemorySecrets, UserDefaults) throws -> Void) rethrows {
        let suite = "MontageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecrets()
        try body(CredentialRepository(defaults: defaults, secrets: secrets), secrets, defaults)
    }
    func testFailedReplacementNeverReactivatesOldTokenOrWritesPlaintext() throws {
        try withRepository { repository, secrets, defaults in
            secrets.values["Token"] = "old"
            secrets.failWrite = true
            XCTAssertThrowsError(try repository.save("Token", value: "new"))
            XCTAssertEqual(try repository.read("Token"), "")
            XCTAssertNil(defaults.string(forKey: "Token"))
        }
    }
    func testFailedLogoutCannotResurrectToken() throws {
        try withRepository { repository, secrets, defaults in
            secrets.values["Token"] = "old"
            defaults.set("legacy", forKey: "Token")
            secrets.failDelete = true
            XCTAssertThrowsError(try repository.clear("Token"))
            XCTAssertEqual(try repository.read("Token", migrateLegacy: true), "")
            XCTAssertNil(defaults.string(forKey: "Token"))
        }
    }
    func testMigrationRemovesPlaintextOnlyAfterVerifiedWrite() throws {
        try withRepository { repository, secrets, defaults in
            defaults.set("legacy", forKey: "Token")
            secrets.failWrite = true
            XCTAssertThrowsError(try repository.read("Token", migrateLegacy: true))
            XCTAssertEqual(defaults.string(forKey: "Token"), "legacy")
            XCTAssertEqual(try repository.read("Token"), "")
            secrets.failWrite = false
            XCTAssertEqual(try repository.read("Token", migrateLegacy: true), "legacy")
            XCTAssertNil(defaults.string(forKey: "Token"))
            XCTAssertEqual(secrets.values["Token"], "legacy")
        }
    }
    func testMigrationReplacesStaleKeychainItemWithNewestLegacyToken() throws {
        try withRepository { repository, secrets, defaults in
            defaults.set("newest", forKey: "Token")
            secrets.values["Token"] = "stale"
            XCTAssertEqual(try repository.read("Token", migrateLegacy: true), "newest")
            XCTAssertEqual(secrets.values["Token"], "newest")
            XCTAssertNil(defaults.string(forKey: "Token"))
        }
    }
    func testMismatchedVerificationKeepsLegacyCopyAndReportsFailure() throws {
        try withRepository { repository, secrets, defaults in
            defaults.set("legacy", forKey: "Token")
            secrets.mismatchReadAfterWrite = true
            XCTAssertThrowsError(try repository.read("Token", migrateLegacy: true))
            XCTAssertEqual(defaults.string(forKey: "Token"), "legacy")
        }
    }
    func testValidatedSnapshotBoundsNonFiniteValuesAndTitleDuration() {
        let settings = SaverSettings(rows: -1, columns: 999, autoColumns: true, rotationInterval: .infinity,
            imageSource: .mixed, showTitleReveal: true, titleDisplayDuration: .nan, librarySelection: .selected([]))
        XCTAssertEqual(settings.rows, 1); XCTAssertEqual(settings.columns, 10)
        XCTAssertEqual(settings.rotationInterval, 5); XCTAssertEqual(settings.titleDisplayDuration, 2)
        XCTAssertFalse(settings.librarySelection.includes("Movies"))
        let fastest = SaverSettings(rows: 3, columns: 4, autoColumns: false, rotationInterval: 2,
            imageSource: .fanart, showTitleReveal: true, titleDisplayDuration: .nan, librarySelection: .all)
        XCTAssertEqual(fastest.titleDisplayDuration, 1)
        XCTAssertTrue(fastest.librarySelection.includes("Movies"))
    }
    func testRuntimeSnapshotRejectsEndpointChangeWhileTokenReadIsPending() async throws {
        let previous = (Preferences.providerType, Preferences.plexServerURL, Preferences.plexAccountID, Preferences.plexServerID)
        defer {
            Preferences.providerType = previous.0; Preferences.plexServerURL = previous.1
            Preferences.plexAccountID = previous.2; Preferences.plexServerID = previous.3
        }
        Preferences.providerType = .plex; Preferences.plexServerURL = "https://old-endpoint.invalid"
        Preferences.plexAccountID = "same-account"; Preferences.plexServerID = UUID().uuidString
        let reader = DeferredSnapshotToken()
        let request = Task { try await Preferences.connectionSnapshot { key in try await reader.read(key) } }
        // Reading a fresh cross-process snapshot can wait on cfprefsd before
        // credential lookup starts. Bound the wait in time, not scheduler turns.
        for _ in 0..<100 where !(await reader.started) { try await Task.sleep(nanoseconds: 10_000_000) }
        let started = await reader.started
        XCTAssertTrue(started)
        guard started else { request.cancel(); return }
        Preferences.plexServerURL = "https://new-endpoint.invalid"
        await reader.finish()
        do { _ = try await request.value; XCTFail("An endpoint change must invalidate the pending token snapshot") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testLibrarySelectionsAreSavedPerConnectionAndKeepExplicitEmpty() {
        let one = ConnectionProfile(provider: .jellyfin, serverURL: "https://one.invalid", accountID: UUID().uuidString)
        let two = ConnectionProfile(provider: .jellyfin, serverURL: "https://one.invalid", accountID: UUID().uuidString)
        defer {
            Preferences.defaults.removeObject(forKey: "LibrarySelection.\(one.namespace)")
            Preferences.defaults.removeObject(forKey: "LibrarySelection.\(two.namespace)")
        }
        Preferences.saveLibrarySelection(.selected([]), for: one)
        Preferences.saveLibrarySelection(.selected(["movies"]), for: two)
        XCTAssertEqual(Preferences.librarySelection(for: one), .selected([]))
        XCTAssertEqual(Preferences.librarySelection(for: two), .selected(["movies"]))
    }
    func testCacheProfileSeparatesAccountsAndPreservesPathCase() {
        let first = ConnectionProfile(provider: .jellyfin, serverURL: "HTTPS://EXAMPLE.COM/Jellyfin/", accountID: "one")
        let equivalent = ConnectionProfile(provider: .jellyfin, serverURL: "https://example.com/Jellyfin", accountID: "one")
        let second = ConnectionProfile(provider: .jellyfin, serverURL: "https://example.com/Jellyfin", accountID: "two")
        let otherPath = ConnectionProfile(provider: .jellyfin, serverURL: "https://example.com/jellyfin", accountID: "one")
        XCTAssertEqual(first.namespace, equivalent.namespace)
        XCTAssertNotEqual(first.namespace, second.namespace)
        XCTAssertNotEqual(first.namespace, otherPath.namespace)
        XCTAssertFalse(first.namespace.contains("example"))
    }
}
