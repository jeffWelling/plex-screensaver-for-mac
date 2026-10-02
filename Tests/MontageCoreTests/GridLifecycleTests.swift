import XCTest
import AppKit
import QuartzCore
@testable import MontageCore

private actor GridArtworkProvider: MediaProvider {
    nonisolated let serverName = "Grid lifecycle fixture"
    private let image: NSImage
    private let delay: UInt64
    private let suspendAfterFirst: Bool
    private var requestCount = 0
    private var suspended: CheckedContinuation<NSImage, Never>?
    private var requestStarted: CheckedContinuation<Void, Never>?
    private var didSuspend = false

    init(image: NSImage, delay: UInt64 = 20_000_000, suspendAfterFirst: Bool = false) {
        self.image = image
        self.delay = delay
        self.suspendAfterFirst = suspendAfterFirst
    }

    func fetchLibraries() async throws -> [MediaLibrary] {
        [MediaLibrary(id: "grid", name: "Grid fixture", type: "movies")]
    }

    func fetchItems(libraryId: String) async throws -> [MediaItem] {
        makeItems(6, artPrefix: "/grid-fixture/")
    }

    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        requestCount += 1
        if suspendAfterFirst && requestCount > 1 {
            // Deliberately finish after cancellation to exercise generation checks.
            return await withCheckedContinuation {
                suspended = $0
                didSuspend = true
                requestStarted?.resume()
                requestStarted = nil
            }
        }
        try await Task.sleep(nanoseconds: delay)
        return image
    }

    func waitForSuspendedRequest() async {
        if didSuspend { return }
        await withCheckedContinuation { requestStarted = $0 }
    }

    func finishSuspendedRequest() {
        suspended?.resume(returning: image)
        suspended = nil
    }
}

final class GridLifecycleTests: XCTestCase {
    @MainActor
    private func image(red: CGFloat = 0.5) -> NSImage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 8, height: 8))
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if await condition() { return true }
            CATransaction.flush()
            try? await Task.sleep(nanoseconds: 10_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return await condition()
    }

    @MainActor
    func testCellClearReleasesImagesTitlesAndUpdatesBackingScale() {
        let cell = GridCell(frame: CGRect(x: 0, y: 0, width: 160, height: 90), row: 0, column: 0)
        XCTAssertTrue(cell.displayImage(image(), transitionDuration: 0))
        cell.showTitle("A retained title", fadeDuration: 0)
        let layers = cell.containerLayer.sublayers!
        XCTAssertEqual(layers.prefix(2).filter { $0.contents != nil }.count, 1)
        XCTAssertEqual((layers.last as? CATextLayer)?.string as? String, "A retained title")

        cell.updateBackingScale(3)
        XCTAssertTrue(layers.allSatisfy { $0.contentsScale == 3 })
        cell.clear()
        XCTAssertTrue(layers.prefix(2).allSatisfy { $0.contents == nil && $0.opacity == 0 })
        XCTAssertTrue(layers.suffix(2).allSatisfy { $0.opacity == 0 })
        XCTAssertNil((layers.last as? CATextLayer)?.string)
    }

    @MainActor
    func testImmediateReplacementClearsOutgoingTextureAndCompletesOnce() {
        let cell = GridCell(frame: CGRect(x: 0, y: 0, width: 160, height: 90), row: 0, column: 0)
        var completions = 0
        XCTAssertTrue(cell.displayImage(image(red: 0.2), transitionDuration: 0) { completions += 1 })
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(cell.displayImage(image(red: 0.8), transitionDuration: 0) { completions += 1 })
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(cell.containerLayer.sublayers!.prefix(2).filter { $0.contents != nil }.count, 1)
    }

    @MainActor
    func testProgressiveInitialFillCompletesBeforeAnyRotationTick() async {
        let provider = GridArtworkProvider(image: image())
        let registry = ReservationRegistry()
        let pool = ImagePool(provider: provider, namespace: UUID().uuidString, imageSource: .fanart,
                             cellWidth: 8, cellHeight: 8, poolSize: 2, registry: registry)
        _ = await pool.loadMediaItems(selection: .all)
        let firstPrefill = await pool.prefill(count: 1)
        XCTAssertEqual(firstPrefill, 1)
        let grid = GridManager(frame: CGRect(x: 0, y: 0, width: 480, height: 90), rows: 1,
                               columns: 3, rotationInterval: 30, showTitleReveal: false)
        var firstArtworkCalls = 0
        grid.onFirstArtwork = { firstArtworkCalls += 1 }
        grid.startRotation(imagePool: pool)
        // Repeated starts must retain one fill task and one periodic timer.
        grid.startRotation(imagePool: pool)
        let filled = await waitUntil { grid.occupiedCellCount == 3 }
        XCTAssertTrue(filled, "one prefetched image must lead to a full grid without waiting 30 seconds")
        XCTAssertEqual(firstArtworkCalls, 1)
        XCTAssertEqual(grid.reservationCount, 3)
        let reserved = await registry.count
        XCTAssertEqual(reserved, 3)
        grid.stopRotation()
        await pool.stop()
    }

    @MainActor
    func testStopDuringProgressiveFillRejectsLateArtwork() async {
        let provider = GridArtworkProvider(image: image(), suspendAfterFirst: true)
        let registry = ReservationRegistry()
        let pool = ImagePool(provider: provider, namespace: UUID().uuidString, imageSource: .fanart,
                             cellWidth: 8, cellHeight: 8, poolSize: 2, registry: registry)
        _ = await pool.loadMediaItems(selection: .all)
        _ = await pool.prefill(count: 1)
        let grid = GridManager(frame: CGRect(x: 0, y: 0, width: 480, height: 90), rows: 1,
                               columns: 3, rotationInterval: 30)
        grid.startRotation(imagePool: pool)
        let showedFirst = await waitUntil { grid.occupiedCellCount == 1 }
        XCTAssertTrue(showedFirst)
        await provider.waitForSuspendedRequest()
        grid.stopRotation()
        await pool.stop()
        await provider.finishSuspendedRequest()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(grid.occupiedCellCount, 0)
        XCTAssertEqual(grid.reservationCount, 0)
        XCTAssertTrue(grid.cells.allSatisfy {
            $0.containerLayer.sublayers!.prefix(2).allSatisfy { $0.contents == nil }
        })
        let reserved = await registry.count
        XCTAssertEqual(reserved, 0)
    }

    @MainActor
    func testTitleRevealKeepsCurrentAndStagedLeasesUntilStop() async {
        let provider = GridArtworkProvider(image: image(), delay: 0)
        let registry = ReservationRegistry()
        let pool = ImagePool(provider: provider, namespace: UUID().uuidString, imageSource: .fanart,
                             cellWidth: 8, cellHeight: 8, poolSize: 3, registry: registry)
        _ = await pool.loadMediaItems(selection: .all)
        _ = await pool.prefill()
        let grid = GridManager(frame: CGRect(x: 0, y: 0, width: 160, height: 90), rows: 1,
                               columns: 1, rotationInterval: 30, titleDisplayDuration: 2)
        grid.startRotation(imagePool: pool)
        let filled = await waitUntil { grid.occupiedCellCount == 1 && grid.reservationCount == 1 }
        XCTAssertTrue(filled)
        grid.rotateWeightedRandomCell()
        let staged = await waitUntil { grid.reservationCount == 2 }
        XCTAssertTrue(staged)
        XCTAssertEqual(grid.occupiedCellCount, 1)
        let reservedBeforeStop = await registry.count
        XCTAssertEqual(reservedBeforeStop, 2, "both displayed and staged artwork must remain reserved during reveal")
        grid.stopRotation()
        let drained = await waitUntil { await registry.count == 0 }
        XCTAssertTrue(drained, "stop must release staged artwork as well as the visible occupant")
        await pool.stop()
    }

    @MainActor
    func testCrossfadeCompletionClearsOutgoingTextureAndReleasesItsLease() async throws {
        let registry = ReservationRegistry()
        let firstReservation = await registry.reserve(artPath: "/first", titleKey: "first")
        let secondReservation = await registry.reserve(artPath: "/second", titleKey: "second")
        let first = try XCTUnwrap(firstReservation)
        let second = try XCTUnwrap(secondReservation)
        let cell = GridCell(frame: CGRect(x: 0, y: 0, width: 160, height: 90), row: 0, column: 0)
        cell.displayImage(image(red: 0.2), transitionDuration: 0)
        var completed = false
        cell.displayImage(image(red: 0.8), transitionDuration: 0.05) {
            completed = true
            Task { await registry.release(lease: first) }
        }
        XCTAssertFalse(completed, "the outgoing lease must survive until transition completion")
        XCTAssertEqual(cell.containerLayer.sublayers!.prefix(2).filter { $0.contents != nil }.count, 2)
        let finished = await waitUntil { completed }
        XCTAssertTrue(finished)
        let released = await waitUntil { await registry.count == 1 }
        XCTAssertTrue(released)
        XCTAssertEqual(cell.containerLayer.sublayers!.prefix(2).filter { $0.contents != nil }.count, 1)
        await registry.release(lease: second)
        cell.clear()
    }
}
