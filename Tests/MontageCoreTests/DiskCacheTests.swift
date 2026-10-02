import XCTest
import AppKit
@testable import MontageCore

private final class CacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ interval: TimeInterval) { lock.lock(); date = date.addingTimeInterval(interval); lock.unlock() }
}

private func bitmapImage(width: Int = 8, height: Int = 8) -> NSImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
}

final class DiskCacheTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("montage-cache-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testSeparateInstancesMergeManifestUnderFileLock() async throws {
        let directory = try temporaryDirectory()
        let a = DiskCache(namespace: "account", directory: directory)
        let b = DiskCache(namespace: "account", directory: directory)
        let itemA = MediaItem(id: "a", title: "Movie A", year: 2000,
                              artPaths: [.fanart: "/a"], libraryId: "library-a")
        let itemB = MediaItem(id: "b", title: "Movie B", year: 2001,
                              artPaths: [.fanart: "/b"], libraryId: "library-b")
        async let first = a.store("/a", image: bitmapImage(), item: itemA, source: .fanart, width: 8, height: 8)
        async let second = b.store("/b", image: bitmapImage(), item: itemB, source: .fanart, width: 8, height: 8)
        let stored = await (first, second)
        XCTAssertTrue(stored.0)
        XCTAssertTrue(stored.1)
        let summaryA = await a.summary()
        let summaryB = await b.summary()
        XCTAssertEqual(summaryA.count, 2)
        XCTAssertEqual(summaryB.count, 2)
        XCTAssertGreaterThan(summaryA.sizeBytes, 0)
    }

    func testAccountIsolationAndStrictMetadataLibrarySelection() async throws {
        let directory = try temporaryDirectory()
        let a = DiskCache(namespace: "account-a", directory: directory)
        let b = DiskCache(namespace: "account-b", directory: directory)
        var item = makeItems(1)[0]
        item.libraryId = "selected"
        await a.store("/art", image: bitmapImage(), item: item, source: .fanart, width: 8, height: 8)
        let leaked = await b.get("/art")
        let none = await a.cachedImages(limit: 10, selection: .selected([]), imageSource: .fanart, width: 4, height: 4)
        let wrong = await a.cachedImages(limit: 10, selection: .selected(["other"]), imageSource: .fanart, width: 4, height: 4)
        let selected = await a.cachedImages(limit: 10, selection: .selected(["selected"]), imageSource: .fanart, width: 4, height: 4)
        XCTAssertNil(leaked)
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(wrong.isEmpty)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.item.title, item.title)
        XCTAssertEqual(selected.first?.item.year, item.year)
        XCTAssertEqual(selected.first?.item.titleKey, item.titleKey)
    }

    func testSmallVariantCannotSatisfyLargeRequestButLargeCanSatisfySmall() async throws {
        let cache = DiskCache(namespace: "sizes", directory: try temporaryDirectory())
        let item = makeItems(1)[0]
        await cache.store("/art", image: bitmapImage(width: 4, height: 4), item: item, source: .fanart, width: 4, height: 4)
        let undersized = await cache.get("/art", width: 8, height: 8)
        XCTAssertNil(undersized)
        await cache.store("/art", image: bitmapImage(width: 8, height: 8), item: item, source: .fanart, width: 8, height: 8)
        let adequate = await cache.get("/art", width: 6, height: 6)
        let summary = await cache.summary()
        XCTAssertNotNil(adequate)
        XCTAssertEqual(summary.count, 2)
        // AppKit may expose a doubled bitmap representation on Retina hosts.
        // The cache contract is sufficient display pixels, rather than an
        // exact backing representation size chosen by the current host SDK.
        let image = try XCTUnwrap(adequate)
        XCTAssertGreaterThanOrEqual(image.representations.first?.pixelsWide ?? 0, 6)
        XCTAssertGreaterThanOrEqual(image.representations.first?.pixelsHigh ?? 0, 6)
    }

    func testAccessDoesNotMakeStaleArtworkFreshAndOfflineFallbackRemains() async throws {
        let clock = CacheClock()
        let cache = DiskCache(namespace: "freshness", directory: try temporaryDirectory(), now: { clock.read() })
        let item = makeItems(1)[0]
        await cache.store("/art", image: bitmapImage(), item: item, source: .fanart, width: 8, height: 8)
        let downloadedAt = (await cache.summary()).lastRefresh
        clock.advance(DiskCache.maxAge + 100)
        let fresh = await cache.get("/art", width: 8, height: 8, allowStale: false)
        let offline = await cache.get("/art", width: 8, height: 8)
        let summary = await cache.summary()
        let isFresh = await cache.isFresh
        XCTAssertNil(fresh)
        XCTAssertNotNil(offline)
        XCTAssertFalse(isFresh)
        XCTAssertEqual(summary.lastRefresh, downloadedAt)
    }

    func testOrphanFilesAndCorruptArtworkAreRemoved() async throws {
        let directory = try temporaryDirectory()
        let cache = DiskCache(namespace: "orphans", directory: directory)
        await cache.store("/art", image: bitmapImage(), item: makeItems(1)[0], source: .fanart, width: 8, height: 8)
        let scoped = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let orphan = scoped.appendingPathComponent("orphan.jpg")
        try Data(repeating: 1, count: 32).write(to: orphan)
        _ = await cache.summary()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        let artwork = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: scoped, includingPropertiesForKeys: nil).first { $0.pathExtension == "jpg" })
        try Data("corrupt".utf8).write(to: artwork)
        let image = await cache.get("/art")
        let summary = await cache.summary()
        XCTAssertNil(image)
        XCTAssertEqual(summary.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artwork.path))
    }

    func testRestoredMetadataUsesSameOwnedPoolAndNoNetwork() async throws {
        let cache = DiskCache(namespace: "restoration", directory: try temporaryDirectory())
        var item = makeItems(1)[0]
        item.libraryId = "lib"
        await cache.store("/art", image: bitmapImage(), item: item, source: .fanart, width: 8, height: 8)
        let registry = ReservationRegistry()
        let pool = ImagePool(provider: MockProvider(itemsByLibrary: [:], failImages: true), namespace: "restoration",
                             imageSource: .fanart, cellWidth: 4, cellHeight: 4, poolSize: 4,
                             diskCache: cache, registry: registry)
        let count = await pool.restoreCachedImages(selection: .selected(["lib"]))
        let restored = await pool.takeImage()
        let image = try XCTUnwrap(restored)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(image.title, item.title)
        XCTAssertEqual(image.year, item.year)
        XCTAssertNotNil(image.lease)
        await pool.release(item: image)
        await pool.stop()
        let final = await registry.count
        XCTAssertEqual(final, 0)
    }

    func testCancelledReadDoesNotDeleteValidArtwork() async throws {
        let cache = DiskCache(namespace: "cancelled-read", directory: try temporaryDirectory())
        await cache.store("/art", image: bitmapImage(), item: makeItems(1)[0], source: .fanart, width: 8, height: 8)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.get("/art", width: 4, height: 4)
        }
        _ = await cancelled.value
        let count = await cache.count
        let image = await cache.get("/art", width: 4, height: 4)
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(image)
    }

    func testSourceSelectionFiltersCachedArtwork() async throws {
        let cache = DiskCache(namespace: "source", directory: try temporaryDirectory())
        let poster = MediaItem(id: "poster", title: "Poster", year: nil, artPaths: [.posters: "/poster"])
        await cache.store("/poster", image: bitmapImage(), item: poster, source: .posters, width: 8, height: 8)
        let backgrounds = await cache.cachedImages(limit: 4, selection: .all, imageSource: .fanart, width: 4, height: 4)
        let both = await cache.cachedImages(limit: 4, selection: .all, imageSource: .mixed, width: 4, height: 4)
        XCTAssertTrue(backgrounds.isEmpty)
        XCTAssertEqual(both.count, 1)
    }
}
