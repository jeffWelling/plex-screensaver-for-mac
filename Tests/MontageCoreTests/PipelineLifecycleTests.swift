import XCTest
import AppKit
@testable import MontageCore

private actor SuspendedImageProvider: MediaProvider {
    nonisolated let serverName = "Suspended test provider"
    private var completion: CheckedContinuation<NSImage, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false

    func fetchLibraries() async throws -> [MediaLibrary] {
        [MediaLibrary(id: "lib", name: "Library", type: "movies")]
    }
    func fetchItems(libraryId: String) async throws -> [MediaItem] { makeItems(4) }
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        // Deliberately emulate a provider that completes after cancellation.
        await withCheckedContinuation { continuation in
            completion = continuation
            didStart = true
            started?.resume()
            started = nil
        }
    }
    func waitForRequest() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { completion?.resume(returning: NSImage(size: NSSize(width: 4, height: 4))); completion = nil }
}

private actor CountingImageProvider: MediaProvider {
    nonisolated let serverName = "Counting test provider"
    private(set) var requests = 0
    let items: [MediaItem]
    init(count: Int = 4) { items = makeItems(count) }
    func fetchLibraries() async throws -> [MediaLibrary] { [MediaLibrary(id: "lib", name: "Library", type: "movies")] }
    func fetchItems(libraryId: String) async throws -> [MediaItem] { items }
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        requests += 1
        return NSImage(size: NSSize(width: width, height: height))
    }
}

final class PipelineLifecycleTests: XCTestCase {
    func testStopDuringPrefillRejectsLateImageAndReservations() async {
        let provider = SuspendedImageProvider()
        let registry = ReservationRegistry()
        let pool = ImagePool(provider: provider, namespace: UUID().uuidString, imageSource: .fanart,
                             cellWidth: 4, cellHeight: 4, poolSize: 4, registry: registry)
        _ = await pool.loadMediaItems(selection: .all)
        let fill = Task { await pool.prefill(count: 1) }
        await provider.waitForRequest()
        await pool.stop()
        await provider.finish()
        let result = await fill.value
        let image = await pool.takeImage()
        let stats = await pool.stats()
        let reserved = await registry.count
        XCTAssertEqual(result, 0)
        XCTAssertNil(image)
        XCTAssertEqual(stats.poolDepth, 0)
        XCTAssertEqual(stats.lastRefillResult, "stopped")
        XCTAssertEqual(reserved, 0)
    }

    func testCancelledStartupRejectsLateImage() async {
        let provider = SuspendedImageProvider()
        let pool = ImagePool(provider: provider, namespace: UUID().uuidString, imageSource: .fanart,
                             cellWidth: 4, cellHeight: 4, poolSize: 4, registry: ReservationRegistry())
        _ = await pool.loadMediaItems(selection: .all)
        let fill = Task { await pool.prefill(count: 1) }
        await provider.waitForRequest()
        fill.cancel()
        await provider.finish()
        _ = await fill.value
        let stats = await pool.stats()
        XCTAssertEqual(stats.poolDepth, 0)
        await pool.stop()
    }

    func testLateLeaseReleaseCannotUnreserveNewOwner() async throws {
        let registry = ReservationRegistry()
        let first = await registry.reserve(artPath: "/art", titleKey: "movie|2020")
        let old = try XCTUnwrap(first)
        await registry.release(lease: old)
        let second = await registry.reserve(artPath: "/art", titleKey: "movie|2020")
        let current = try XCTUnwrap(second)
        await registry.release(lease: old)
        let stillReserved = await registry.reserve(artPath: "/art", titleKey: "movie|2020")
        let count = await registry.count
        XCTAssertNil(stillReserved)
        XCTAssertEqual(count, 1)
        await registry.release(lease: current)
        await registry.release(lease: current)
        let final = await registry.count
        XCTAssertEqual(final, 0)
    }

    func testConcurrentReservationHasExactlyOneWinner() async {
        let registry = ReservationRegistry()
        async let a = registry.reserve(artPath: "/art", titleKey: "title")
        async let b = registry.reserve(artPath: "/art", titleKey: "title")
        let results = await [a, b].compactMap { $0 }
        XCTAssertEqual(results.count, 1)
        if let lease = results.first { await registry.release(lease: lease) }
    }

    func testCancellingOneCoalescedOwnerKeepsOtherMonitorDownloadAlive() async throws {
        let coalescer = ImageRequestCoalescer()
        let provider = SuspendedImageProvider()
        let ownerA = UUID()
        let ownerB = UUID()
        let first = Task {
            try await coalescer.image(for: "same-size-key", owner: ownerA) {
                try await provider.fetchImage(path: "/art", width: 4, height: 4)
            }
        }
        await provider.waitForRequest()
        let second = Task {
            try await coalescer.image(for: "same-size-key", owner: ownerB) {
                XCTFail("a coalesced request must not fetch a second time")
                return NSImage(size: NSSize(width: 4, height: 4))
            }
        }
        for _ in 0..<1000 {
            if await coalescer.activeWaiterCount(for: "same-size-key") == 2 { break }
            await Task.yield()
        }
        let waiters = await coalescer.activeWaiterCount(for: "same-size-key")
        XCTAssertEqual(waiters, 2)
        await coalescer.cancel(owner: ownerA)
        await provider.finish()
        do {
            _ = try await first.value
            XCTFail("a cancelled owner must not receive the shared result")
        } catch { XCTAssertTrue(error is CancellationError) }
        let image = try await second.value
        XCTAssertEqual(image.size.width, 4)
    }

    func testDifferentAccountsDoNotCollideOnRelativePath() async {
        let registry = ReservationRegistry()
        let a = await registry.reserve(artPath: "/art", titleKey: "title", namespace: "account-a")
        let b = await registry.reserve(artPath: "/art", titleKey: "title", namespace: "account-b")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        if let a { await registry.release(lease: a) }
        if let b { await registry.release(lease: b) }
    }

    func testProgressivePrefillFetchesOneImageAndSmallLibraryRotates() async throws {
        let provider = CountingImageProvider(count: 2)
        let pool = ImagePool(provider: provider, namespace: UUID().uuidString, imageSource: .fanart,
                             cellWidth: 4, cellHeight: 4, poolSize: 20, registry: ReservationRegistry())
        let count = await pool.loadMediaItems(selection: .all)
        let filled = await pool.prefill(count: 1)
        let requests = await provider.requests
        XCTAssertEqual(count, 2)
        XCTAssertEqual(filled, 1)
        XCTAssertEqual(requests, 1)
        var rotations = 0
        for _ in 0..<10 {
            _ = await pool.prefill(count: 1)
            var taken: ImageWithMetadata?
            for _ in 0..<1000 {
                if let image = await pool.takeImage() { taken = image; break }
                await Task.yield()
            }
            let image = try XCTUnwrap(taken)
            rotations += 1
            await pool.release(item: image)
        }
        XCTAssertEqual(rotations, 10)
        let stats = await pool.stats()
        XCTAssertLessThanOrEqual(stats.poolDepth, 2)
        await pool.stop()
    }

    func testEmptyExplicitLibrarySelectionDoesNotLoadEverything() async {
        let pool = ImagePool(provider: CountingImageProvider(), namespace: UUID().uuidString,
                             imageSource: .fanart, cellWidth: 4, cellHeight: 4, poolSize: 4)
        let count = await pool.loadMediaItems(selection: .selected([]))
        let filled = await pool.prefill()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(filled, 0)
        await pool.stop()
    }
}
