import AppKit
import XCTest
@testable import MontageCore

private func preparationImage(width: Int = 16, height: Int = 16) -> NSImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return PreparedArtwork.image(context.makeImage()!)
}
private actor PreparationProvider: MediaProvider {
    nonisolated let serverName = "Preparation fixture"
    nonisolated let filterCapabilities = MediaFilterCapabilities(supportsGenres: true, supportsCollections: true, supportsFavorites: true, supportsUnwatched: true)
    var items: [String: [MediaItem]]
    var fails = false
    var suspends = false
    private var continuation: CheckedContinuation<NSImage, Error>?
    private var imageWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var paths: [String] = []
    var imageStarted: Bool { continuation != nil }
    init(_ items: [String: [MediaItem]]) { self.items = items }
    func setFailure(_ value: Bool) { fails = value }
    func setSuspended(_ value: Bool) { suspends = value }
    func waitForImage() async {
        if continuation != nil { return }
        await withCheckedContinuation { imageWaiters.append($0) }
    }
    func finish() { continuation?.resume(returning: preparationImage()); continuation = nil }
    func fetchLibraries() async throws -> [MediaLibrary] { items.keys.sorted().map { MediaLibrary(id: $0, name: $0, type: "movies") } }
    func fetchItems(libraryId: String) async throws -> [MediaItem] { items[libraryId] ?? [] }
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        paths.append(path)
        if fails { throw MockError.imageFailed }
        if suspends {
            return try await withCheckedThrowingContinuation {
                continuation = $0
                let waiting = imageWaiters; imageWaiters.removeAll()
                for waiter in waiting { waiter.resume() }
            }
        }
        return preparationImage(width: width, height: height)
    }
}

final class OfflineArtworkPreparationTests: XCTestCase {
    private func cache() throws -> DiskCache {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("montage-preparation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return DiskCache(namespace: "test", directory: directory)
    }
    private var connection: ConnectionSnapshot { ConnectionSnapshot(provider: .jellyfin, serverURL: "https://test.invalid", token: "fixture", userID: "u", accountID: "u") }
    private func settings(selection: LibrarySelection = .all, source: ImageSourceType = .fanart, filter: MediaFilter = MediaFilter()) -> SaverSettings {
        SaverSettings(rows: 3, columns: 4, autoColumns: false, rotationInterval: 5, imageSource: source,
            showTitleReveal: true, titleDisplayDuration: 2, librarySelection: selection, mediaFilter: filter)
    }
    func testFailedRefreshPreservesOfflineArtworkAndDownloadDate() async throws {
        let cache = try cache()
        var item = makeItems(1)[0]; item.libraryId = "a"
        await cache.store("/art/0", image: preparationImage(), item: item, source: .fanart, width: 16, height: 16)
        let before = await cache.summary()
        let provider = PreparationProvider(["a": [item]])
        await provider.setFailure(true)
        let service = OfflineArtworkPreparation(makeProvider: { _ in provider }, makeCache: { _ in cache })
        let result = try await service.prepare(connection: connection, settings: settings(), width: 16, height: 16, refreshExisting: true) { _ in }
        let after = await cache.summary()
        let fallback = await cache.get("/art/0", width: 16, height: 16)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after.lastRefresh, before.lastRefresh)
        XCTAssertNil(after.lastPreparedDate)
        XCTAssertNotNil(fallback)
    }
    func testPreparationHonorsSelectedLibrariesFiltersAndSource() async throws {
        let cache = try cache()
        let keep = MediaItem(id: "keep", title: "Keep", year: nil, artPaths: [.fanart: "/keep", .posters: "/poster"], genres: ["Drama"], isFavorite: true, isWatched: false)
        let exclude = MediaItem(id: "exclude", title: "Exclude", year: nil, artPaths: [.fanart: "/exclude"], genres: ["Comedy"], isFavorite: true, isWatched: false)
        let provider = PreparationProvider(["selected": [keep, exclude], "other": makeItems(2)])
        let service = OfflineArtworkPreparation(makeProvider: { _ in provider }, makeCache: { _ in cache })
        let filter = MediaFilter(genres: ["Drama"], favoritesOnly: true, unwatchedOnly: true)
        let chosen = settings(selection: .selected(["selected"]), source: .posters, filter: filter)
        let result = try await service.prepare(connection: connection, settings: chosen, width: 16, height: 16, refreshExisting: false) { _ in }
        let paths = await provider.paths
        let ready = await service.readiness(connection: connection, settings: chosen, width: 16, height: 16)
        XCTAssertEqual(paths, ["/poster"])
        XCTAssertEqual(result.downloaded, 1)
        XCTAssertEqual(ready.readyTitles, 1)
        XCTAssertNotNil(ready.lastPreparedDate)
    }
    func testCancellationRejectsLateImageWithoutMarkingPreparationComplete() async throws {
        let cache = try cache(), provider = PreparationProvider(["a": makeItems(2)])
        await provider.setSuspended(true)
        let service = OfflineArtworkPreparation(makeProvider: { _ in provider }, makeCache: { _ in cache })
        let connection = connection, settings = settings()
        let task = Task { try await service.prepare(connection: connection, settings: settings, width: 16, height: 16, refreshExisting: false) { _ in } }
        await provider.waitForImage()
        let started = await provider.imageStarted
        XCTAssertTrue(started)
        task.cancel(); await provider.finish()
        do { _ = try await task.value; XCTFail("Canceled preparation must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        let summary = await cache.summary()
        XCTAssertEqual(summary.count, 0)
        XCTAssertNil(summary.lastPreparedDate)
    }
    func testBoundedRepeatedPreparationContinuesWithUnpreparedTitles() async throws {
        let cache = try cache(), provider = PreparationProvider(["a": makeItems(3)])
        let service = OfflineArtworkPreparation(maximumTitles: 1, makeProvider: { _ in provider }, makeCache: { _ in cache })
        let first = try await service.prepare(connection: connection, settings: settings(), width: 16, height: 16, refreshExisting: false) { _ in }
        let second = try await service.prepare(connection: connection, settings: settings(), width: 16, height: 16, refreshExisting: false) { _ in }
        let paths = await provider.paths
        let ready = await service.readiness(connection: connection, settings: settings(), width: 16, height: 16)
        XCTAssertTrue(first.limited); XCTAssertTrue(second.limited)
        XCTAssertEqual(paths.count, 2)
        XCTAssertNotEqual(paths[0], paths[1])
        XCTAssertEqual(ready.readyTitles, 2)
    }
    func testReadinessCountsUniqueMatchingTitlesAtRequestedSize() async throws {
        let cache = try cache()
        let item = MediaItem(id: "a", title: "A", year: nil, artPaths: [.fanart: "/a", .posters: "/poster"], libraryId: "selected", genres: ["Drama"], isFavorite: true, isWatched: false)
        let small = MediaItem(id: "small", title: "Small", year: nil, artPaths: [.fanart: "/small"], libraryId: "selected", genres: ["Drama"], isFavorite: true, isWatched: false)
        let other = MediaItem(id: "other", title: "Other", year: nil, artPaths: [.fanart: "/other"], libraryId: "unselected", genres: ["Drama"], isFavorite: true, isWatched: false)
        await cache.store("/a", image: preparationImage(), item: item, source: .fanart, width: 16, height: 16)
        await cache.store("/poster", image: preparationImage(), item: item, source: .posters, width: 16, height: 16)
        await cache.store("/small", image: preparationImage(width: 4, height: 4), item: small, source: .fanart, width: 4, height: 4)
        await cache.store("/other", image: preparationImage(), item: other, source: .fanart, width: 16, height: 16)
        let service = OfflineArtworkPreparation(makeCache: { _ in cache })
        let filter = MediaFilter(genres: ["Drama"], favoritesOnly: true, unwatchedOnly: true)
        let ready = await service.readiness(connection: connection, settings: settings(selection: .selected(["selected"]), source: .mixed, filter: filter), width: 16, height: 16)
        XCTAssertEqual(ready.readyTitles, 1)
    }
    func testSuccessfulCatalogRefreshUpdatesFilterMetadataWithoutRemovingArtwork() async throws {
        let cache = try cache()
        let old = MediaItem(id: "a", title: "A", year: nil, artPaths: [.fanart: "/a"], libraryId: "library", isFavorite: true, isWatched: false)
        let fresh = MediaItem(id: "a", title: "A", year: nil, artPaths: [.fanart: "/a"], isFavorite: false, isWatched: true)
        await cache.store("/a", image: preparationImage(), item: old, source: .fanart, width: 16, height: 16)
        let provider = PreparationProvider(["library": [fresh]])
        let service = OfflineArtworkPreparation(makeProvider: { _ in provider }, makeCache: { _ in cache })
        let chosen = settings(filter: MediaFilter(favoritesOnly: true, unwatchedOnly: true))
        _ = try await service.prepare(connection: connection, settings: chosen, width: 16, height: 16, refreshExisting: true) { _ in }
        let ready = await service.readiness(connection: connection, settings: chosen, width: 16, height: 16)
        let summary = await cache.summary()
        XCTAssertEqual(ready.readyTitles, 0)
        XCTAssertEqual(summary.count, 1)
        let paths = await provider.paths
        XCTAssertTrue(paths.isEmpty)
    }
    func testMixedPreparationKeepsBothOrientationsWithinTheTitleBudget() async throws {
        let cache = try cache()
        let item = MediaItem(id: "both", title: "Both", year: nil, artPaths: [.fanart: "/wide", .posters: "/portrait"])
        let provider = PreparationProvider(["a": [item]])
        let service = OfflineArtworkPreparation(maximumTitles: 1, makeProvider: { _ in provider }, makeCache: { _ in cache })
        let result = try await service.prepare(connection: connection, settings: settings(source: .mixed), width: 16, height: 8, refreshExisting: false) { _ in }
        let paths = await provider.paths
        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.downloaded, 2)
        XCTAssertEqual(paths, ["/wide", "/portrait"])
        let summary = await cache.summary()
        XCTAssertEqual(summary.count, 2)
    }
    func testPreparationResolvesRequestSizeAfterKnowingEligibleCatalogCount() async throws {
        let cache = try cache(), provider = PreparationProvider(["a": makeItems(3)])
        let service = OfflineArtworkPreparation(makeProvider: { _ in provider }, makeCache: { _ in cache },
            resolveDimensions: { _, count, _, _ in (count == 3 ? 24 : 1, 24) })
        _ = try await service.prepare(connection: connection, settings: settings(), width: 4, height: 4, refreshExisting: false) { _ in }
        let records = await cache.availableArtwork(selection: .all, imageSource: .fanart, width: 24, height: 24)
        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records.allSatisfy { $0.width == 24 && $0.height == 24 })
    }

    func testSharedPhotoPathRetainsExplicitArtworkSource() async throws {
        let cache = try cache()
        let item = MediaItem(id: "photo", title: "Photo", year: nil, artPaths: [.fanart: "/photo", .posters: "/photo"])
        let provider = PreparationProvider(["a": [item]])
        let service = OfflineArtworkPreparation(makeProvider: { _ in provider }, makeCache: { _ in cache })
        _ = try await service.prepare(connection: connection, settings: settings(source: .fanart), width: 16, height: 16, refreshExisting: false) { _ in }
        let ready = await service.readiness(connection: connection, settings: settings(source: .fanart), width: 16, height: 16)
        XCTAssertEqual(ready.readyTitles, 1)
    }

    func testAlreadyPreparedCatalogDoesNotOfferAnEndlessAdditionalBatch() async throws {
        let cache = try cache(), items = makeItems(3), provider = PreparationProvider(["a": makeItems(3)])
        for item in items {
            var tagged = item; tagged.libraryId = "a"
            await cache.store(item.artPaths[.fanart]!, image: preparationImage(), item: tagged, source: .fanart, width: 16, height: 16)
        }
        let service = OfflineArtworkPreparation(maximumTitles: 1, makeProvider: { _ in provider }, makeCache: { _ in cache })
        let result = try await service.prepare(connection: connection, settings: settings(), width: 16, height: 16, refreshExisting: false) { _ in }
        XCTAssertTrue(result.alreadyPrepared)
        XCTAssertEqual(result.matchingTitles, 3)
        XCTAssertEqual(result.checked, 0)
        XCTAssertEqual(result.downloaded, 0)
        XCTAssertFalse(result.limited)
        XCTAssertTrue(result.message.contains("already prepared"))
        XCTAssertFalse(result.message.contains("run it again"))
        let paths = await provider.paths
        XCTAssertTrue(paths.isEmpty)
    }
    func testEmptySelectionHasNoMatchingArtworkInsteadOfClaimingAlreadyPrepared() async throws {
        let cache = try cache(), provider = PreparationProvider(["a": makeItems(2)])
        let service = OfflineArtworkPreparation(makeProvider: { _ in provider }, makeCache: { _ in cache })
        let result = try await service.prepare(connection: connection, settings: settings(selection: .selected([])), width: 16, height: 16, refreshExisting: false) { _ in }
        XCTAssertFalse(result.alreadyPrepared)
        XCTAssertEqual(result.matchingTitles, 0)
        XCTAssertEqual(result.checked, 0)
        XCTAssertFalse(result.limited)
        XCTAssertTrue(result.message.contains("No artwork matches"))
    }
    func testRefreshStillChecksPreparedTitlesWithinItsBoundedBatch() async throws {
        let cache = try cache(), items = makeItems(3), provider = PreparationProvider(["a": makeItems(3)])
        for item in items {
            var tagged = item; tagged.libraryId = "a"
            await cache.store(item.artPaths[.fanart]!, image: preparationImage(), item: tagged, source: .fanart, width: 16, height: 16)
        }
        let service = OfflineArtworkPreparation(maximumTitles: 1, makeProvider: { _ in provider }, makeCache: { _ in cache })
        let result = try await service.prepare(connection: connection, settings: settings(), width: 16, height: 16, refreshExisting: true) { _ in }
        XCTAssertFalse(result.alreadyPrepared)
        XCTAssertTrue(result.limited)
        XCTAssertEqual(result.checked, 1)
        XCTAssertEqual(result.downloaded, 1)
        let paths = await provider.paths
        XCTAssertEqual(paths.count, 1)
    }

}
