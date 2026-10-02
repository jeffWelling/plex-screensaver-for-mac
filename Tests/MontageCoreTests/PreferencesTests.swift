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
        for _ in 0..<100 where !(await reader.started) { await Task.yield() }
        let started = await reader.started
        XCTAssertTrue(started)
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
