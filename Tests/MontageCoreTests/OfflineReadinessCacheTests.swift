import XCTest
import AppKit
@testable import MontageCore

final class OfflineReadinessCacheTests: XCTestCase {
    private func cache(_ namespace: String = "readiness") throws -> (DiskCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("montage-ready-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (DiskCache(namespace: namespace, directory: directory), directory)
    }
    private func image(_ width: Int = 16, _ height: Int = 16) -> NSImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return PreparedArtwork.image(context.makeImage()!)
    }
    private func item(_ id: String, library: String = "lib", watched: Bool = false) -> MediaItem {
        MediaItem(id: id, title: "Title \(id)", year: 2000, artPaths: [.fanart: "/\(id)", .posters: "/\(id)/poster"],
            libraryId: library, genres: ["Comedy"], collections: ["Classics"], isFavorite: true, isWatched: watched)
    }

    func testReadinessCountsUsableTitlesForCurrentSelectionAndFilter() async throws {
        let (cache, _) = try cache()
        let first = item("a")
        await cache.store("/a", image: image(), item: first, source: .fanart, width: 16, height: 16)
        await cache.store("/a/poster", image: image(), item: first, source: .posters, width: 16, height: 16)
        await cache.store("/b", image: image(), item: item("b", library: "other"), source: .fanart, width: 16, height: 16)
        await cache.store("/c", image: image(), item: item("c", watched: true), source: .fanart, width: 16, height: 16)
        let ready = await cache.availableArtwork(selection: .selected(["lib"]), imageSource: .mixed,
            filter: MediaFilter(unwatchedOnly: true), width: 8, height: 8)
        XCTAssertEqual(ready.map { $0.item.id }, ["a"])
        let none = await cache.availableArtwork(selection: .selected([]), imageSource: .mixed, width: 8, height: 8)
        XCTAssertTrue(none.isEmpty)
    }

    func testReadinessDistinguishesSmallOfflineFallbackFromAdequateArtwork() async throws {
        let (cache, _) = try cache()
        await cache.store("/a", image: image(4, 4), item: item("a"), source: .fanart, width: 4, height: 4)
        let adequate = await cache.availableArtwork(selection: .all, imageSource: .fanart, width: 8, height: 8)
        let fallback = await cache.availableArtwork(selection: .all, imageSource: .fanart, width: 8, height: 8, requireAdequateSize: false)
        XCTAssertTrue(adequate.isEmpty)
        XCTAssertEqual(fallback.count, 1)
    }

    func testReadinessRejectsCorruptFilesWithoutRetainingBitmaps() async throws {
        let (cache, directory) = try cache()
        await cache.store("/a", image: image(), item: item("a"), source: .fanart, width: 16, height: 16)
        let scoped = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let file = scoped.appendingPathComponent(DiskCache.filename(for: "/a|16x16"))
        try Data("invalid image".utf8).write(to: file)
        let ready = await cache.availableArtwork(selection: .all, imageSource: .fanart, width: 8, height: 8)
        XCTAssertTrue(ready.isEmpty)
    }

    func testCatalogRefreshPreservesArtworkAndUpdatesOfflineFilters() async throws {
        let (cache, _) = try cache()
        await cache.store("/a", image: image(), item: item("a"), source: .fanart, width: 16, height: 16)
        let before = await cache.summary()
        await cache.refreshMetadata([item("a", watched: true)], libraryIDs: ["lib"])
        let after = await cache.summary()
        let unfiltered = await cache.availableArtwork(selection: .all, imageSource: .fanart, width: 8, height: 8)
        let filtered = await cache.availableArtwork(selection: .all, imageSource: .fanart,
            filter: MediaFilter(unwatchedOnly: true), width: 8, height: 8)
        XCTAssertEqual(before.sizeBytes, after.sizeBytes)
        XCTAssertEqual(before.lastRefresh, after.lastRefresh)
        XCTAssertEqual(unfiltered.count, 1)
        XCTAssertTrue(filtered.isEmpty)
        let oldArtwork = await cache.get("/a", width: 8, height: 8)
        XCTAssertNotNil(oldArtwork)
    }

    func testOfflineQueueHonorsFilterAndRecentHistory() async throws {
        let (cache, _) = try cache()
        await cache.store("/a", image: image(), item: item("a", watched: true), source: .fanart, width: 16, height: 16)
        await cache.store("/b", image: image(), item: item("b"), source: .fanart, width: 16, height: 16)
        await cache.store("/c", image: image(), item: item("c"), source: .fanart, width: 16, height: 16)
        let queue = await cache.cachedImages(limit: 2, selection: .all, imageSource: .fanart, width: 8, height: 8,
            filter: MediaFilter(unwatchedOnly: true), recentTitleDates: [RecentTitleHistory.digest(item("c").titleKey): Date()])
        XCTAssertEqual(queue.map { $0.item.id }, ["b", "c"])
    }

    func testPreparedLowResolutionOriginalRemainsOfflineReady() async throws {
        let (cache, _) = try cache()
        await cache.store("/a", image: image(4, 4), item: item("a"), source: .fanart, width: 16, height: 16)
        let prepared = await cache.availableArtwork(selection: .all, imageSource: .fanart, width: 16, height: 16)
        XCTAssertEqual(prepared.count, 1, "An original image cannot acquire detail through repeated downloads")
    }

    func testLocalPhotoPreparedUnderPostersWorksWithBackgrounds() async throws {
        let (cache, _) = try cache()
        let photo = MediaItem(id: "photo", title: "Photo", year: nil,
            artPaths: [.fanart: "photo-key", .posters: "photo-key"], libraryId: "local", mediaType: "photo")
        await cache.store("photo-key", image: image(), item: photo, source: .posters, width: 16, height: 16)
        let ready = await cache.availableArtwork(selection: .all, imageSource: .fanart, width: 8, height: 8)
        let queue = await cache.cachedImages(limit: 2, selection: .all, imageSource: .fanart, width: 8, height: 8)
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first?.source, .fanart)
        XCTAssertEqual(queue.count, 1)
    }

    func testCanceledStoreAndCompletionDoNotWrite() async throws {
        let (cache, _) = try cache()
        let artwork = image()
        let metadata = item("a")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await cache.store("/a", image: artwork, item: metadata, source: .fanart, width: 16, height: 16)
            await cache.markPreparationCompleted()
        }
        await task.value
        let summary = await cache.summary()
        XCTAssertEqual(summary.count, 0)
        XCTAssertNil(summary.lastPreparedDate)
    }

    func testPreparationTimestampPersistsAcrossCacheInstances() async throws {
        let (cache, directory) = try cache()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        await cache.markPreparationCompleted(date)
        let reloaded = DiskCache(namespace: "readiness", directory: directory)
        let summary = await reloaded.summary()
        XCTAssertEqual(summary.lastPreparedDate, date)
        await reloaded.clear()
        let cleared = await cache.summary()
        XCTAssertNil(cleared.lastPreparedDate)
    }
}
