import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import MontageCore

final class LocalArtworkTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("montage-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func image(at url: URL, type: UTType = .png) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testBookmarkRoundTripAndOpaqueFolderIdentity() throws {
        let root = try folder()
        let bookmark = try LocalArtworkFolder.bookmark(for: root)
        XCTAssertEqual(try LocalArtworkFolder.resolve(bookmarkData: bookmark).standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertEqual(LocalArtworkFolder.displayName(bookmarkData: bookmark), root.lastPathComponent)
        let identity = LocalArtworkFolder.identity(for: root)
        XCTAssertEqual(identity.count, 64)
        XCTAssertFalse(identity.contains(root.lastPathComponent))
        XCTAssertEqual(identity, LocalArtworkFolder.identity(for: root.appendingPathComponent(".")))
    }

    func testBookmarkRejectsNetworkURLAndInvalidData() throws {
        XCTAssertThrowsError(try LocalArtworkFolder.bookmark(for: URL(string: "https://example.invalid/art")!))
        XCTAssertThrowsError(try LocalArtworkFolder.resolve(bookmarkData: Data()))
        XCTAssertThrowsError(try LocalArtworkFolder.resolve(bookmarkData: Data("bad".utf8)))
        let root = try folder()
        let file = root.appendingPathComponent("photo.png")
        try image(at: file)
        XCTAssertThrowsError(try LocalArtworkFolder.bookmark(for: file))
    }

    func testRecursiveCatalogueSkipsHiddenNonImagesAndSymlinks() async throws {
        let root = try folder()
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try image(at: root.appendingPathComponent("first.png"))
        try image(at: nested.appendingPathComponent("second.tiff"), type: .tiff)
        try image(at: root.appendingPathComponent(".hidden.png"))
        try Data("not artwork".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let outside = try folder()
        try image(at: outside.appendingPathComponent("secret.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.png"), withDestinationURL: outside.appendingPathComponent("secret.png"))
        let provider = try LocalArtworkProvider(bookmarkData: LocalArtworkFolder.bookmark(for: root))
        XCTAssertFalse(provider.requiresNetwork)
        let libraries = try await provider.fetchLibraries()
        XCTAssertEqual(libraries.map(\.id), [LocalArtworkProvider.libraryID])
        let items = try await provider.fetchItems(libraryId: LocalArtworkProvider.libraryID)
        XCTAssertEqual(Set(items.map(\.title)), ["first", "second"])
        for item in items {
            XCTAssertEqual(item.id.count, 64)
            XCTAssertEqual(item.artPaths[.fanart]?.count, 64)
            XCTAssertEqual(item.artPaths[.posters], item.artPaths[.fanart])
            XCTAssertEqual(item.libraryId, LocalArtworkProvider.libraryID)
            XCTAssertFalse(item.id.contains(root.path))
        }
        let unknown = try await provider.fetchItems(libraryId: "unknown")
        XCTAssertTrue(unknown.isEmpty)
        let options = try await provider.fetchFilterOptions(libraryIds: libraries.map(\.id))
        XCTAssertEqual(options, MediaFilterOptions())
    }

    func testImageReadIsBoundedAndCachedCatalogueKeyWorksBeforeInitialScan() async throws {
        let root = try folder()
        try image(at: root.appendingPathComponent("photo.png"))
        let bookmark = try LocalArtworkFolder.bookmark(for: root)
        let first = try LocalArtworkProvider(bookmarkData: bookmark)
        let items = try await first.fetchItems(libraryId: LocalArtworkProvider.libraryID)
        let path = try XCTUnwrap(items.first?.artPaths[.fanart])
        let reopened = try LocalArtworkProvider(bookmarkData: bookmark)
        let artwork = try await reopened.fetchImage(path: path, width: 12, height: 8)
        XCTAssertEqual(artwork.size.width, 12)
        XCTAssertEqual(artwork.size.height, 8)
        do { _ = try await reopened.fetchImage(path: "../../outside.png", width: 12, height: 8); XCTFail("Traversal must fail") }
        catch { XCTAssertEqual(error as? LocalArtworkError, .missingArtwork) }
    }

    func testSymlinkReplacementAfterCatalogueDiscoveryCannotEscapeFolder() async throws {
        let root = try folder()
        let photo = root.appendingPathComponent("photo.png")
        try image(at: photo)
        let outside = try folder().appendingPathComponent("outside.png")
        try image(at: outside)
        let provider = try LocalArtworkProvider(bookmarkData: LocalArtworkFolder.bookmark(for: root))
        let items = try await provider.fetchItems(libraryId: LocalArtworkProvider.libraryID)
        let item = try XCTUnwrap(items.first)
        try FileManager.default.removeItem(at: photo)
        try FileManager.default.createSymbolicLink(at: photo, withDestinationURL: outside)
        do { _ = try await provider.fetchImage(path: item.artPaths[.fanart]!, width: 12, height: 8); XCTFail("Symlink must fail") }
        catch { XCTAssertEqual(error as? LocalArtworkError, .missingArtwork) }
    }

    func testParentDirectorySymlinkReplacementCannotEscapeFolder() async throws {
        let root = try folder()
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try image(at: nested.appendingPathComponent("photo.png"))
        let provider = try LocalArtworkProvider(bookmarkData: LocalArtworkFolder.bookmark(for: root))
        let items = try await provider.fetchItems(libraryId: LocalArtworkProvider.libraryID)
        let item = try XCTUnwrap(items.first)
        let outside = try folder().appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.moveItem(at: nested, to: outside)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)
        do { _ = try await provider.fetchImage(path: item.artPaths[.fanart]!, width: 12, height: 8); XCTFail("Parent symlink must fail") }
        catch { XCTAssertEqual(error as? LocalArtworkError, .missingArtwork) }
    }

    func testArtworkKeyChangesWhenFileRevisionChanges() async throws {
        let root = try folder()
        let photo = root.appendingPathComponent("photo.png")
        try image(at: photo)
        let provider = try LocalArtworkProvider(bookmarkData: LocalArtworkFolder.bookmark(for: root))
        let firstItems = try await provider.fetchItems(libraryId: LocalArtworkProvider.libraryID)
        let first = try XCTUnwrap(firstItems.first)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: photo.path)
        let updatedItems = try await provider.fetchItems(libraryId: LocalArtworkProvider.libraryID)
        let updated = try XCTUnwrap(updatedItems.first)
        XCTAssertEqual(first.id, updated.id)
        XCTAssertNotEqual(first.artPaths[.fanart], updated.artPaths[.fanart])
    }

    func testSameFilenameInDifferentFoldersHasDistinctDisplayIdentity() async throws {
        let root = try folder()
        for name in ["a", "b"] {
            let nested = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try image(at: nested.appendingPathComponent("IMG_0001.png"))
        }
        let provider = try LocalArtworkProvider(bookmarkData: LocalArtworkFolder.bookmark(for: root))
        let items = try await provider.fetchItems(libraryId: LocalArtworkProvider.libraryID)
        XCTAssertEqual(items.count, 2)
        guard items.count == 2 else { return }
        XCTAssertNotEqual(items[0].titleKey, items[1].titleKey)
    }

    func testCachedOnlyFallbackDoesNotAcquireAccessAndReportsStableErrors() async {
        let provider = CachedOnlyLocalArtworkProvider()
        XCTAssertFalse(provider.requiresNetwork)
        XCTAssertFalse(provider.filterCapabilities.hasFilters)
        do { _ = try await provider.fetchLibraries(); XCTFail("Expected unavailable folder") }
        catch { XCTAssertEqual(error as? LocalArtworkError, .chooseFolderAgain) }
        do { _ = try await provider.fetchItems(libraryId: LocalArtworkProvider.libraryID); XCTFail("Expected unavailable folder") }
        catch { XCTAssertEqual(error as? LocalArtworkError, .chooseFolderAgain) }
        do { _ = try await provider.fetchImage(path: "cached", width: 12, height: 8); XCTFail("Expected unavailable folder") }
        catch { XCTAssertEqual(error as? LocalArtworkError, .chooseFolderAgain) }
    }

    func testNetworkProvidersRequireNetworkByDefault() {
        XCTAssertTrue(PlexProvider(serverURL: "https://fixture.invalid", token: "token").requiresNetwork)
        XCTAssertTrue(JellyfinProvider(serverURL: "https://fixture.invalid", accessToken: "token", userId: "user").requiresNetwork)
    }

    func testRecoveringProviderReopensUnavailableFolderInSameSession() async throws {
        let root = try folder()
        try image(at: root.appendingPathComponent("photo.png"))
        let bookmark = try LocalArtworkFolder.bookmark(for: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        let provider = RecoveringLocalArtworkProvider(bookmarkData: bookmark)
        XCTAssertFalse(provider.requiresNetwork)
        do { _ = try await provider.fetchItems(libraryId: LocalArtworkProvider.libraryID); XCTFail("Expected unavailable folder") }
        catch { XCTAssertEqual(error as? LocalArtworkError, .chooseFolderAgain) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let libraries = try await provider.fetchLibraries()
        XCTAssertEqual(libraries.map(\.id), [LocalArtworkProvider.libraryID])
        let items = try await provider.fetchItems(libraryId: LocalArtworkProvider.libraryID)
        let path = try XCTUnwrap(items.first?.artPaths[.fanart])
        let artwork = try await provider.fetchImage(path: path, width: 12, height: 8)
        XCTAssertEqual(artwork.size, NSSize(width: 12, height: 8))
    }

    func testRecoveryReopensAfterPreviouslyAvailableFolderFails() async throws {
        let root = try folder()
        try image(at: root.appendingPathComponent("photo.png"))
        let bookmark = try LocalArtworkFolder.bookmark(for: root)
        let attempts = LocalProviderLifetimeProbe()
        let provider = RecoveringLocalArtworkProvider(bookmarkData: bookmark,
            initialProvider: try LocalArtworkProvider(bookmarkData: bookmark)) { data in
                attempts.recordAttempt()
                return try LocalArtworkProvider(bookmarkData: data)
            }
        let initial = try await provider.fetchItems(libraryId: LocalArtworkProvider.libraryID)
        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(attempts.attemptCount, 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        do { _ = try await provider.fetchItems(libraryId: LocalArtworkProvider.libraryID); XCTFail("Expected unavailable folder") }
        catch { XCTAssertEqual(error as? LocalArtworkError, .chooseFolderAgain) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let recovered = try await provider.fetchItems(libraryId: LocalArtworkProvider.libraryID)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(attempts.attemptCount, 1)
    }

    func testRecoveryDoesNotRetryOpeningForEveryUnavailableImage() async throws {
        let attempts = LocalProviderLifetimeProbe()
        let provider = RecoveringLocalArtworkProvider(bookmarkData: Data()) { _ in
            attempts.recordAttempt()
            throw LocalArtworkError.chooseFolderAgain
        }
        for _ in 0..<3 {
            do { _ = try await provider.fetchImage(path: "saved", width: 12, height: 8); XCTFail("Expected unavailable folder") }
            catch { XCTAssertEqual(error as? LocalArtworkError, .chooseFolderAgain) }
        }
        XCTAssertEqual(attempts.attemptCount, 0)
        do { _ = try await provider.fetchLibraries(); XCTFail("Expected unavailable folder") }
        catch { XCTAssertEqual(error as? LocalArtworkError, .chooseFolderAgain) }
        do { _ = try await provider.fetchItems(libraryId: LocalArtworkProvider.libraryID); XCTFail("Expected unavailable folder") }
        catch { XCTAssertEqual(error as? LocalArtworkError, .chooseFolderAgain) }
        XCTAssertEqual(attempts.attemptCount, 2)
    }

    func testCancellationDuringRecoveryReleasesProvisionalProvider() async throws {
        let root = try folder()
        let bookmark = try LocalArtworkFolder.bookmark(for: root)
        let lifetime = LocalProviderLifetimeProbe()
        let provider = RecoveringLocalArtworkProvider(bookmarkData: bookmark) { data in
            let opened = try LocalArtworkProvider(bookmarkData: data)
            lifetime.record(opened)
            withUnsafeCurrentTask { $0?.cancel() }
            return opened
        }
        let task = Task { try await provider.fetchLibraries() }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertTrue(lifetime.isReleased)
        do { _ = try await provider.fetchImage(path: "saved", width: 12, height: 8); XCTFail("Canceled provisional provider must not be retained") }
        catch { XCTAssertEqual(error as? LocalArtworkError, .chooseFolderAgain) }
    }

    func testMissingFolderReportsActionableSelectionError() throws {
        let root = try folder()
        let bookmark = try LocalArtworkFolder.bookmark(for: root)
        try FileManager.default.removeItem(at: root)
        XCTAssertThrowsError(try LocalArtworkProvider(bookmarkData: bookmark)) {
            XCTAssertEqual($0 as? LocalArtworkError, .chooseFolderAgain)
        }
    }
}

/// Synchronizes the factory callback and test task without retaining the local
/// provider whose scope/descriptor lifecycle is under examination.
private final class LocalProviderLifetimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var opened: LocalArtworkProvider?
    private var attempts = 0
    func record(_ provider: LocalArtworkProvider) { lock.lock(); opened = provider; lock.unlock() }
    func recordAttempt() { lock.lock(); attempts += 1; lock.unlock() }
    var attemptCount: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    var isReleased: Bool { lock.lock(); defer { lock.unlock() }; return opened == nil }
}
