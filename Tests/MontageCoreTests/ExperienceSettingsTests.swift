import XCTest
import AppKit
@testable import MontageCore

final class ExperienceSettingsTests: XCTestCase {
    private func settings() -> SaverSettings {
        SaverSettings(rows: 4, columns: 5, autoColumns: false, rotationInterval: 8,
            imageSource: .mixed, showTitleReveal: true, titleDisplayDuration: 3,
            librarySelection: .selected(["favorites"]),
            mediaFilter: MediaFilter(genres: ["Comedy"], collections: ["Classics"], unwatchedOnly: true))
    }

    func testPresetsRetainLibraryAndMetadataChoices() {
        let original = settings()
        for preset in PresentationPreset.allCases {
            let applied = original.applying(preset)
            XCTAssertEqual(applied.librarySelection, original.librarySelection)
            XCTAssertEqual(applied.mediaFilter, original.mediaFilter)
        }
        let poster = original.applying(.posterWall)
        XCTAssertEqual(poster.imageSource, .posters)
        XCTAssertTrue(poster.autoColumns)
        XCTAssertEqual(poster.artworkFraming, .fit)
        let calm = original.applying(.calm)
        XCTAssertEqual(calm.rows * calm.columns, 1)
        XCTAssertEqual(calm.rotationInterval, 60)
        XCTAssertFalse(calm.showTitleReveal)
        XCTAssertEqual(calm.transitionDuration, 2)
    }

    func testSettingsBoundNewTimingAndKeepLegacyDefaults() {
        let legacy = settings()
        XCTAssertEqual(legacy.artworkFraming, .fill)
        XCTAssertEqual(legacy.transitionDuration, 1)
        let slow = SaverSettings(rows: 1, columns: 1, autoColumns: false, rotationInterval: 999,
            imageSource: .fanart, showTitleReveal: true, titleDisplayDuration: 999,
            librarySelection: .all, artworkFraming: .fit, transitionDuration: .infinity)
        XCTAssertEqual(slow.rotationInterval, 120)
        XCTAssertEqual(slow.transitionDuration, 1)
        XCTAssertEqual(slow.titleDisplayDuration, 119)
        let finite = SaverSettings(rows: 1, columns: 1, autoColumns: false, rotationInterval: 30,
            imageSource: .fanart, showTitleReveal: true, titleDisplayDuration: 999,
            librarySelection: .all, transitionDuration: 999)
        XCTAssertEqual(finite.transitionDuration, 3)
        XCTAssertEqual(finite.titleDisplayDuration, 27)
    }

    func testFilterPreferencesAreScopedToConnection() {
        let first = ConnectionProfile(provider: .plex, serverURL: "https://one.invalid", accountID: UUID().uuidString)
        let second = ConnectionProfile(provider: .plex, serverURL: "https://two.invalid", accountID: UUID().uuidString)
        defer {
            Preferences.defaults.removeObject(forKey: "MediaFilter.\(first.namespace)")
            Preferences.defaults.removeObject(forKey: "MediaFilter.\(second.namespace)")
        }
        let filter = settings().mediaFilter
        Preferences.saveMediaFilter(filter, for: first)
        XCTAssertEqual(Preferences.mediaFilter(for: first), filter)
        XCTAssertTrue(Preferences.mediaFilter(for: second).isEmpty)
    }

    @MainActor
    func testPreviewDoesNotChangeActiveDisplayAllocation() throws {
        let count = InstanceTracker.shared.activeCount
        let preview = try XCTUnwrap(MontageView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), isPreview: true))
        preview.configurePreview(settings: settings(), connection: ConnectionSnapshot(provider: .local,
            serverURL: "", token: "", userID: "", accountID: "isolated-preview"))
        preview.startAnimation()
        XCTAssertEqual(InstanceTracker.shared.activeCount, count)
        preview.stopAnimation()
        XCTAssertEqual(InstanceTracker.shared.activeCount, count)
    }

    func testLocalSnapshotDoesNotReadServerCredentials() async throws {
        let previous = (Preferences.providerType, Preferences.localFolderBookmark, Preferences.localFolderIdentity)
        defer {
            Preferences.providerType = previous.0
            Preferences.localFolderBookmark = previous.1
            Preferences.localFolderIdentity = previous.2
        }
        Preferences.providerType = .local
        Preferences.localFolderIdentity = "isolated-\(UUID())"
        Preferences.localFolderBookmark = Data("bookmark-fixture".utf8)
        let connection = try await Preferences.connectionSnapshot { _ in
            XCTFail("Local artwork must not read server credentials")
            return "unexpected"
        }
        XCTAssertEqual(connection.provider, .local)
        XCTAssertEqual(connection.localFolderBookmark, Preferences.localFolderBookmark)
        XCTAssertEqual(connection.token, "")
        XCTAssertEqual(connection.profile.accountID, Preferences.localFolderIdentity)
    }
}
