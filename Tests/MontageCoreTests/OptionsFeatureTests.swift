import AppKit
import XCTest
@testable import MontageCore

private actor OptionsCredentials: ConfigurationCredentials {
    private(set) var saved: [String] = []
    private(set) var cleared: [String] = []
    func read(_ key: String, allowInteraction: Bool) async throws -> String { "" }
    func save(_ key: String, value: String) async throws { saved.append(key) }
    func clear(_ key: String) async throws { cleared.append(key) }
}
private struct EmptyOptionsServices: ConfigurationServices {
    func plexSignIn(status: @escaping @Sendable (String) async -> Void) async throws -> String { "account" }
    func plexAccountID(token: String) async throws -> String { "account" }
    func plexServers(token: String) async throws -> [PlexServer] { [] }
    func libraries(connection: ConnectionSnapshot) async throws -> [MediaLibrary] { [] }
    func jellyfinSignIn(serverURL: String, username: String, password: String) async throws -> (accessToken: String, userId: String) { ("token", "user") }
}
private actor OptionsPreparation: OfflineArtworkPreparing {
    private(set) var refreshFlags: [Bool] = []
    private var continuation: CheckedContinuation<OfflineArtworkPreparationResult, Error>?
    var started: Bool { continuation != nil }
    func readiness(connection: ConnectionSnapshot, settings: SaverSettings, width: Int, height: Int) async -> OfflineArtworkReadiness { .empty }
    func prepare(connection: ConnectionSnapshot, settings: SaverSettings, width: Int, height: Int, refreshExisting: Bool,
                 progress: @escaping @Sendable (OfflineArtworkProgress) async -> Void) async throws -> OfflineArtworkPreparationResult {
        refreshFlags.append(refreshExisting)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: OfflineArtworkPreparationResult(checked: 1, downloaded: 1, failed: 0, limited: false)); continuation = nil }
}

@MainActor final class OptionsFeatureTests: XCTestCase {
    func testCancelDiscardsSettingsAndStagedSignOutWithoutCredentialWrites() async {
        let credentials = OptionsCredentials()
        let model = ConfigurationViewModel(services: EmptyOptionsServices(), credentials: credentials, restoreCredentials: false)
        model.plexServerURL = "https://cancel-\(UUID()).invalid"; model.plexToken = "installed-token"; model.isSignedIn = true
        let before = NSDictionary(dictionary: Preferences.defaults.dictionaryRepresentation())
        model.gridRows = 8; model.artworkFraming = .fit; model.mediaFilter = MediaFilter(genres: ["Drama"])
        model.signOut()
        XCTAssertFalse(model.isSignedIn)
        var dismissed = false
        model.cancel { dismissed = true }
        for _ in 0..<20 { await Task.yield() }
        let saved = await credentials.saved, cleared = await credentials.cleared
        XCTAssertTrue(dismissed)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(cleared.isEmpty, "Sign-out is a draft until Apply")
        XCTAssertEqual(before, NSDictionary(dictionary: Preferences.defaults.dictionaryRepresentation()))
    }
    func testCloseButtonUsesCancelInsteadOfSavingSettings() throws {
        _ = NSApplication.shared
        let model = ConfigurationViewModel(services: EmptyOptionsServices(), credentials: OptionsCredentials(), restoreCredentials: false)
        let controller = ConfigureSheetController { model }
        let window = try XCTUnwrap(controller.window)
        let before = NSDictionary(dictionary: Preferences.defaults.dictionaryRepresentation())
        model.gridRows = 9
        XCTAssertFalse(controller.windowShouldClose(window))
        XCTAssertFalse(model.isApplying)
        XCTAssertEqual(before, NSDictionary(dictionary: Preferences.defaults.dictionaryRepresentation()))
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }
    func testPresetsModifyPresentationButKeepLibrariesAndFilters() {
        let model = ConfigurationViewModel(services: EmptyOptionsServices(), credentials: OptionsCredentials(), artworkPreparation: OptionsPreparation(), restoreCredentials: false)
        model.allLibraries = false; model.selectedLibraryIds = ["private-library"]
        model.mediaFilter = MediaFilter(genres: ["Drama"], unwatchedOnly: true)
        let profile = model.currentProfile, filter = model.mediaFilter
        model.applyPreset(.calm)
        XCTAssertEqual(model.gridRows, 1); XCTAssertEqual(model.gridColumns, 1)
        XCTAssertEqual(model.rotationInterval, 60); XCTAssertFalse(model.showTitleReveal)
        XCTAssertEqual(model.artworkFraming, .fit)
        XCTAssertEqual(model.currentSelection, .selected(["private-library"]))
        XCTAssertEqual(model.mediaFilter, filter); XCTAssertEqual(model.currentProfile, profile)
        model.applyPreset(.posterWall)
        XCTAssertEqual(model.imageSource, .posters); XCTAssertTrue(model.gridAutoColumns)
        XCTAssertEqual(model.mediaFilter, filter)
        model.cancelPendingOperations()
    }
    func testRefreshUsesReplacementModeAndCanceledLateCompletionDoesNotPublish() async {
        let preparation = OptionsPreparation()
        let model = ConfigurationViewModel(services: EmptyOptionsServices(), credentials: OptionsCredentials(), artworkPreparation: preparation, restoreCredentials: false)
        model.plexServerURL = "https://refresh-\(UUID()).invalid"; model.plexToken = "fixture"; model.isSignedIn = true
        model.refreshArtwork()
        for _ in 0..<100 where !(await preparation.started) { await Task.yield() }
        let started = await preparation.started
        XCTAssertTrue(started); XCTAssertTrue(model.isManagingCache)
        model.cancelArtworkPreparation()
        let canceledMessage = model.preparationMessage
        await preparation.finish()
        for _ in 0..<20 { await Task.yield() }
        let flags = await preparation.refreshFlags
        XCTAssertEqual(flags, [true])
        XCTAssertFalse(model.isManagingCache)
        XCTAssertNil(model.preparationProgress)
        XCTAssertEqual(model.preparationMessage, canceledMessage)
        model.cancelPendingOperations()
    }
    func testDisplaySleepCancelsBulkPreparation() async {
        let preparation = OptionsPreparation()
        let model = ConfigurationViewModel(services: EmptyOptionsServices(), credentials: OptionsCredentials(), artworkPreparation: preparation, restoreCredentials: false)
        model.plexServerURL = "https://sleep-\(UUID()).invalid"; model.plexToken = "fixture"; model.isSignedIn = true
        model.prepareForOffline()
        for _ in 0..<100 where !(await preparation.started) { await Task.yield() }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        for _ in 0..<100 where model.isManagingCache { await Task.yield() }
        XCTAssertFalse(model.isManagingCache)
        XCTAssertTrue(model.preparationMessage.contains("display sleeps"))
        await preparation.finish()
        model.cancelPendingOperations()
    }
    func testPreviewWindowUsesDraftAndStopsWhenClosed() throws {
        _ = NSApplication.shared
        let before = NSDictionary(dictionary: Preferences.defaults.dictionaryRepresentation())
        let controller = ArtworkPreviewController()
        let settings = SaverSettings(rows: 1, columns: 1, autoColumns: false, rotationInterval: 60, imageSource: .fanart,
            showTitleReveal: false, titleDisplayDuration: 2, librarySelection: .selected([]), artworkFraming: .fit)
        let connection = ConnectionSnapshot(provider: .plex, serverURL: "", token: "", userID: "", accountID: "preview-test")
        controller.show(settings: settings, connection: connection)
        let window = try XCTUnwrap(controller.window), view = try XCTUnwrap(window.contentView as? MontageView)
        XCTAssertTrue(view.isAnimating)
        controller.close()
        XCTAssertFalse(view.isAnimating)
        XCTAssertNil(controller.window)
        XCTAssertEqual(before, NSDictionary(dictionary: Preferences.defaults.dictionaryRepresentation()))
    }
    func testCancelDiscardsStagedLocalFolderBookmark() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("montage-folder-draft-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConfigurationViewModel(services: EmptyOptionsServices(), credentials: OptionsCredentials(), artworkPreparation: OptionsPreparation(), restoreCredentials: false)
        let before = NSDictionary(dictionary: Preferences.defaults.dictionaryRepresentation())
        model.providerType = .local
        model.stageLocalFolder(directory)
        XCTAssertNotNil(model.localFolderBookmark)
        XCTAssertEqual(model.localFolderName, directory.lastPathComponent)
        XCTAssertEqual(model.currentProfile.accountID, LocalArtworkFolder.identity(for: directory))
        model.cancel {}
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(before, NSDictionary(dictionary: Preferences.defaults.dictionaryRepresentation()))
    }

    func testRemoteHostBorderlessPreviewKeepsFocusAndEscapeStopsRenderer() throws {
        _ = NSApplication.shared
        let controller = ArtworkPreviewController()
        let settings = SaverSettings(rows: 1, columns: 1, autoColumns: false, rotationInterval: 60,
            imageSource: .fanart, showTitleReveal: false, titleDisplayDuration: 2, librarySelection: .selected([]))
        let connection = ConnectionSnapshot(provider: .plex, serverURL: "", token: "", userID: "", accountID: "borderless-preview")
        controller.show(settings: settings, connection: connection)
        let window = try XCTUnwrap(controller.window as? ArtworkPreviewWindow)
        let view = try XCTUnwrap(window.contentView as? MontageView)
        window.styleMask = .borderless
        XCTAssertTrue(window.canBecomeKey, "Apple's remote host removes title chrome; the live preview must retain keyboard focus")
        XCTAssertTrue(view.isAnimating)
        window.cancelOperation(nil)
        XCTAssertFalse(view.isAnimating)
        XCTAssertNil(controller.window)
        controller.show(settings: settings, connection: connection)
        let reopened = try XCTUnwrap(controller.window)
        XCTAssertFalse(window === reopened)
        XCTAssertTrue(reopened.canBecomeKey)
        controller.close()
    }

}
