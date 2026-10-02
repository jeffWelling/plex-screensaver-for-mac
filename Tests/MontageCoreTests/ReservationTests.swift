import XCTest
import AppKit
@testable import MontageCore

/// Tests for the core product goal: never display the same media on two cells /
/// monitors at once, and never leak a reservation. Under U4 tier 1 the pool
/// holds *unreserved* candidates and reservation happens at `takeImage()`, so
/// the meaningful invariant is over what is *on screen* (reserved), not over the
/// pool contents. Two `ImagePool`s share one injected `ReservationRegistry` to
/// stand in for two monitors in one process.
final class ReservationTests: XCTestCase {

    func testNoDuplicateOnScreenAndRegistryDrainsToZero() async throws {
        let items = makeItems(30)
        let registry = ReservationRegistry()
        let poolA = ImagePool(provider: MockProvider(itemsByLibrary: ["lib": items]),
                              imageSource: .fanart, cellWidth: 4, cellHeight: 4,
                              poolSize: 6, diskCache: nil, registry: registry)
        let poolB = ImagePool(provider: MockProvider(itemsByLibrary: ["lib": items]),
                              imageSource: .fanart, cellWidth: 4, cellHeight: 4,
                              poolSize: 6, diskCache: nil, registry: registry)

        _ = await poolA.loadMediaItems(libraryIds: ["lib"])
        _ = await poolB.loadMediaItems(libraryIds: ["lib"])
        _ = await poolA.prefill()
        _ = await poolB.prefill()

        var onScreenA: [ImageWithMetadata] = []
        var onScreenB: [ImageWithMetadata] = []
        var rng = SeededGenerator(seed: 0x5EED_1234)
        var successfulTakes = 0

        func assertInvariants(step: Int) async {
            let all = onScreenA + onScreenB
            // 1. No artwork appears in two on-screen cells across both monitors.
            let artPaths = all.map(\.artPath)
            XCTAssertEqual(Set(artPaths).count, artPaths.count, "duplicate artPath on screen at step \(step)")
            // 2. No title (movie identity) appears twice on screen (U5).
            let titleKeys = all.map(\.titleKey)
            XCTAssertEqual(Set(titleKeys).count, titleKeys.count, "duplicate titleKey on screen at step \(step)")
            // 3. The registry holds exactly one reservation per on-screen cell —
            //    no stranded (leaked) reservation accumulates mid-run.
            let count = await registry.count
            XCTAssertEqual(count, all.count, "registry count != on-screen count at step \(step)")
        }

        for step in 0..<400 {
            let useA = Bool.random(using: &rng)
            let take = Bool.random(using: &rng)
            if take {
                if useA {
                    if let item = await poolA.takeImage() { onScreenA.append(item); successfulTakes += 1 }
                } else {
                    if let item = await poolB.takeImage() { onScreenB.append(item); successfulTakes += 1 }
                }
            } else {
                if useA, !onScreenA.isEmpty {
                    let removed = onScreenA.remove(at: Int.random(in: 0..<onScreenA.count, using: &rng))
                    await poolA.release(item: removed)
                } else if !useA, !onScreenB.isEmpty {
                    let removed = onScreenB.remove(at: Int.random(in: 0..<onScreenB.count, using: &rng))
                    await poolB.release(item: removed)
                }
            }
            await assertInvariants(step: step)
        }

        XCTAssertGreaterThan(successfulTakes, 20, "rotation must actually make progress")

        // Leak detector: stop() must return every reservation the pool still
        // holds (including on-screen cells), draining the registry to zero.
        await poolA.stop()
        await poolB.stop()
        let final = await registry.count
        XCTAssertEqual(final, 0, "registry must drain to zero after both pools stop")
    }

    /// U3 leak regression, focused: take a batch, release it, registry returns
    /// to zero (no stranded reservations).
    func testReleaseReturnsRegistryToZero() async throws {
        let registry = ReservationRegistry()
        let pool = ImagePool(provider: MockProvider(itemsByLibrary: ["lib": makeItems(10)]),
                             imageSource: .fanart, cellWidth: 4, cellHeight: 4,
                             poolSize: 5, diskCache: nil, registry: registry)
        _ = await pool.loadMediaItems(libraryIds: ["lib"])
        _ = await pool.prefill()

        var held: [ImageWithMetadata] = []
        for _ in 0..<5 { if let item = await pool.takeImage() { held.append(item) } }
        let afterTakes = await registry.count
        XCTAssertEqual(afterTakes, held.count)

        for item in held { await pool.release(item: item) }
        let afterReleases = await registry.count
        XCTAssertEqual(afterReleases, 0, "every taken reservation must release back to zero")
        await pool.stop()
    }

    /// U3 freeze regression: a pool that drained to empty while the provider was
    /// failing must re-trigger a refill and recover once the provider returns —
    /// the old empty-pool guard-before-trigger never re-scheduled a refill.
    func testEmptyPoolRecoversWhenProviderReturns() async throws {
        let provider = MockProvider(itemsByLibrary: ["lib": makeItems(5)], failImages: true)
        let registry = ReservationRegistry()
        let pool = ImagePool(provider: provider, imageSource: .fanart,
                             cellWidth: 4, cellHeight: 4, poolSize: 4,
                             diskCache: nil, registry: registry, retryInterval: 0)
        _ = await pool.loadMediaItems(libraryIds: ["lib"])

        let filled = await pool.prefill()
        XCTAssertEqual(filled, 0, "provider failing → pool starts empty")

        // Provider recovers before we exercise takeImage's refill trigger, so the
        // deterministic recovery path (not the 30s backoff) is what's tested.
        await provider.setFailImages(false)

        var recovered: ImageWithMetadata?
        for _ in 0..<200 {
            if let item = await pool.takeImage() { recovered = item; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(recovered, "empty pool must re-trigger refill and recover once the provider returns")
        await pool.stop()
    }
}
