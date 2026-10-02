import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import MontageCore

private func pipelineBitmap(width: Int = 8, height: Int = 8) -> NSImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.3, green: 0.2, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
}

private actor BudgetImageProvider: MediaProvider {
    nonisolated let serverName = "Actual bitmap budget fixture"
    private let image: NSImage
    init(image: NSImage) { self.image = image }
    func fetchLibraries() async throws -> [MediaLibrary] { [MediaLibrary(id: "lib", name: "Library", type: "movies")] }
    func fetchItems(libraryId: String) async throws -> [MediaItem] { makeItems(6) }
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage { image }
}

private actor ResizeImageProvider: MediaProvider {
    nonisolated let serverName = "Resize lifecycle fixture"
    private var requests: [(Int, Int)] = []
    private var suspended: CheckedContinuation<NSImage, Never>?
    private var requestStarted: CheckedContinuation<Void, Never>?
    private var didSuspend = false
    func fetchLibraries() async throws -> [MediaLibrary] { [MediaLibrary(id: "lib", name: "Library", type: "movies")] }
    func fetchItems(libraryId: String) async throws -> [MediaItem] { makeItems(6) }
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        requests.append((width, height))
        if width == 8 && requests.count == 2 {
            return await withCheckedContinuation {
                suspended = $0
                didSuspend = true
                requestStarted?.resume()
                requestStarted = nil
            }
        }
        return NSImage(size: NSSize(width: width, height: height))
    }
    func waitForOldRequest() async {
        if didSuspend { return }
        await withCheckedContinuation { requestStarted = $0 }
    }
    func finishOldRequest() {
        suspended?.resume(returning: NSImage(size: NSSize(width: 8, height: 8)))
        suspended = nil
    }
    func requestedSizes() -> [(Int, Int)] { requests }
}

private actor PartialLibraryProvider: MediaProvider {
    nonisolated let serverName = "Partial catalogue fixture"
    private var failedLibraries: [String: MediaNetworkError] = [:]
    private var emptyLibraries = Set<String>()
    func fail(_ libraryID: String, error: MediaNetworkError = .unavailable) { failedLibraries[libraryID] = error }
    func empty(_ libraryID: String) { emptyLibraries.insert(libraryID) }
    func fetchLibraries() async throws -> [MediaLibrary] {
        [MediaLibrary(id: "a", name: "A", type: "movies"), MediaLibrary(id: "b", name: "B", type: "movies")]
    }
    func fetchItems(libraryId: String) async throws -> [MediaItem] {
        if let error = failedLibraries[libraryId] { throw error }
        if emptyLibraries.contains(libraryId) { return [] }
        return [MediaItem(id: libraryId, title: "Movie \(libraryId)", year: 2026,
                          artPaths: [.fanart: "/\(libraryId)"], libraryId: libraryId)]
    }
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage { pipelineBitmap() }
}

final class ImagePipelineHardeningTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("montage-pipeline-budget-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testQueueBudgetUsesActualBitmapCostRatherThanRequestedCellArea() async {
        // The provider deliberately returns much more artwork than the tiny
        // requested cell size, as extreme aspect-fill sources can do.
        let artwork = pipelineBitmap(width: 2048, height: 2048)
        let imageCost = ImageCache.byteCost(of: artwork)
        XCTAssertGreaterThan(imageCost, 8 * 8 * 4)
        let pool = ImagePool(provider: BudgetImageProvider(image: artwork), namespace: UUID().uuidString,
                             imageSource: .fanart, cellWidth: 8, cellHeight: 8, poolSize: 24)
        _ = await pool.loadMediaItems(selection: .all)
        let filled = await pool.prefill()
        let stats = await pool.stats()
        XCTAssertGreaterThan(filled, 0)
        XCTAssertEqual(filled, ImagePool.queueByteLimit / imageCost)
        XCTAssertEqual(stats.queuedBytes, filled * imageCost)
        XCTAssertLessThanOrEqual(stats.queuedBytes, stats.queueByteLimit)
        await pool.stop()
        let stopped = await pool.stats()
        XCTAssertEqual(stopped.queuedBytes, 0)
    }

    func testDiskRestorationStopsDecodingAtItsDecodedByteBudget() async throws {
        let cache = DiskCache(namespace: "decoded-budget", directory: try temporaryDirectory())
        let artwork = pipelineBitmap(width: 512, height: 512)
        for item in makeItems(4) {
            let path = item.artPaths[.fanart]!
            await cache.store(path, image: artwork, item: item, source: .fanart, width: 512, height: 512)
        }
        let sample = await cache.get("/art/0", width: 512, height: 512)
        let oneImage = try XCTUnwrap(sample)
        let budget = ImageCache.byteCost(of: oneImage) * 2
        let cached = await cache.cachedImages(limit: 24, selection: .all, imageSource: .fanart,
                                             width: 512, height: 512, decodedByteLimit: budget)
        XCTAssertEqual(cached.count, 2)
        XCTAssertLessThanOrEqual(cached.reduce(0) { $0 + ImageCache.byteCost(of: $1.image) }, budget)
    }

    func testResizeCancelsOldSizeResultAndPreservesDisplayedLease() async throws {
        let provider = ResizeImageProvider()
        let registry = ReservationRegistry()
        let pool = ImagePool(provider: provider, namespace: UUID().uuidString, imageSource: .fanart,
                             cellWidth: 8, cellHeight: 8, poolSize: 2, registry: registry)
        _ = await pool.loadMediaItems(selection: .all)
        _ = await pool.prefill(count: 1)
        let taken = await pool.takeImage()
        let onScreen = try XCTUnwrap(taken)
        await provider.waitForOldRequest()
        await pool.updateRequestSize(width: 32, height: 16)
        let afterResize = await registry.count
        XCTAssertEqual(afterResize, 1, "resizing pending requests must preserve the displayed lease")
        let newFill = await pool.prefill(count: 1)
        XCTAssertEqual(newFill, 1)
        await provider.finishOldRequest()
        // Allow the deliberately non-cooperative old request to finish its
        // cancellation path before inspecting the current queue.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let stats = await pool.stats()
        XCTAssertEqual(stats.poolDepth, 1)
        let incoming = await pool.takeImage()
        let resized = try XCTUnwrap(incoming)
        XCTAssertEqual(resized.image.size, NSSize(width: 32, height: 16))
        let sizes = await provider.requestedSizes()
        XCTAssertTrue(sizes.contains { $0.0 == 32 && $0.1 == 16 })
        await pool.release(item: onScreen)
        await pool.release(item: resized)
        await pool.stop()
        let reserved = await registry.count
        XCTAssertEqual(reserved, 0)
    }

    func testResizeKeepsOneQueuedFallbackInsteadOfBlankingOfflineDisplay() async throws {
        let pool = ImagePool(provider: BudgetImageProvider(image: pipelineBitmap()), namespace: UUID().uuidString,
                             imageSource: .fanart, cellWidth: 8, cellHeight: 8, poolSize: 3)
        _ = await pool.loadMediaItems(selection: .all)
        _ = await pool.prefill()
        await pool.updateRequestSize(width: 128, height: 128)
        let stats = await pool.stats()
        XCTAssertEqual(stats.poolDepth, 1)
        let fallback = await pool.takeImage()
        XCTAssertNotNil(fallback)
        await pool.stop()
    }

    func testOfflineFallbackAllowsLargestUndersizedVariantWithoutWeakeningOnlineChecks() async throws {
        let cache = DiskCache(namespace: "undersized-fallback", directory: try temporaryDirectory())
        let item = makeItems(1)[0]
        await cache.store("/art", image: pipelineBitmap(width: 8, height: 8), item: item,
                          source: .fanart, width: 8, height: 8)
        await cache.store("/art", image: pipelineBitmap(width: 16, height: 16), item: item,
                          source: .fanart, width: 16, height: 16)
        let online = await cache.get("/art", width: 64, height: 64, allowStale: false)
        let offline = await cache.get("/art", width: 64, height: 64, allowUndersized: true)
        XCTAssertNil(online)
        XCTAssertEqual(try XCTUnwrap(offline).size, NSSize(width: 16, height: 16))
    }

    func testPartialRefreshPreservesOnlyFailedLibraryCatalogueAndTypedError() async throws {
        let provider = PartialLibraryProvider()
        let pool = ImagePool(provider: provider, namespace: UUID().uuidString,
                             imageSource: .fanart, cellWidth: 8, cellHeight: 8, poolSize: 2)
        let initial = await pool.loadMediaItems(selection: .all)
        XCTAssertEqual(initial, 2)
        await provider.fail("b")
        let refreshed = await pool.loadMediaItems(selection: .all)
        let error = await pool.lastLoadError
        XCTAssertEqual(refreshed, 2, "a failed library must retain its previous catalogue")
        XCTAssertEqual(error, .unavailable)
        _ = await pool.prefill()
        let first = await pool.takeImage()
        let second = await pool.takeImage()
        XCTAssertEqual(Set([try XCTUnwrap(first).libraryId, try XCTUnwrap(second).libraryId].compactMap { $0 }), Set(["a", "b"]))
        await pool.stop()
    }

    func testSuccessfulEmptyLibraryRemovesOldItemsWhileFailedLibraryIsRetained() async {
        let provider = PartialLibraryProvider()
        let pool = ImagePool(provider: provider, namespace: UUID().uuidString,
                             imageSource: .fanart, cellWidth: 8, cellHeight: 8, poolSize: 2)
        _ = await pool.loadMediaItems(selection: .all)
        await provider.empty("a")
        await provider.fail("b")
        let refreshed = await pool.loadMediaItems(selection: .all)
        XCTAssertEqual(refreshed, 1, "only the failed library is preserved; an empty successful response is authoritative")
        await pool.stop()
    }

    func testHighBitDepthBitmapCostAndDecoderNormalization() throws {
        let width = 16
        let height = 16
        let bytesPerRow = width * 8
        let data = Data(repeating: 255, count: bytesPerRow * height)
        let source = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                             bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                                 .union(.byteOrder16Big),
                             provider: CGDataProvider(data: data as CFData)!, decode: nil,
                             shouldInterpolate: false, intent: .defaultIntent)!
        let original = NSImage(cgImage: source, size: NSSize(width: width, height: height))
        XCTAssertGreaterThanOrEqual(ImageCache.byteCost(of: original), bytesPerRow * height)
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, source, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let prepared = try ArtworkDecoder.decode(output as Data, width: width, height: height)
        let decoded = try XCTUnwrap(prepared.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(decoded.bitsPerComponent, 8)
        XCTAssertLessThanOrEqual(ImageCache.byteCost(of: prepared), ImagePool.queueByteLimit)
    }

    func testAuthenticationFailureTakesPriorityOverLaterUnavailableLibrary() async {
        let provider = PartialLibraryProvider()
        let pool = ImagePool(provider: provider, namespace: UUID().uuidString,
                             imageSource: .fanart, cellWidth: 8, cellHeight: 8, poolSize: 2)
        _ = await pool.loadMediaItems(selection: .all)
        await provider.fail("a", error: .authenticationRequired)
        await provider.fail("b", error: .unavailable)
        let retained = await pool.loadMediaItems(selection: .all)
        let error = await pool.lastLoadError
        XCTAssertEqual(retained, 2)
        XCTAssertEqual(error, .authenticationRequired)
        await pool.stop()
    }

    @MainActor
    func testFiveKArtworkDecodesWithinBudgetAndFirstCandidateCanBeDisplayed() async throws {
        let source = pipelineBitmap(width: 5120, height: 2880)
        let encoded = try XCTUnwrap(PreparedArtwork.jpegData(source))
        let prepared = try ArtworkDecoder.decode(encoded, width: 8192, height: 8192)
        XCTAssertLessThanOrEqual(ImageCache.byteCost(of: prepared), ImagePool.queueByteLimit)
        let pool = ImagePool(provider: BudgetImageProvider(image: prepared), namespace: UUID().uuidString,
                             imageSource: .fanart, cellWidth: 8192, cellHeight: 8192, poolSize: 24)
        _ = await pool.loadMediaItems(selection: .all)
        let filled = await pool.prefill(count: 1)
        XCTAssertEqual(filled, 1, "the first large candidate must fit instead of leaving the screen black")
        let taken = await pool.takeImage()
        let candidate = try XCTUnwrap(taken)
        let cell = GridCell(frame: CGRect(x: 0, y: 0, width: 512, height: 288), row: 0, column: 0)
        XCTAssertTrue(cell.displayImage(candidate.image, transitionDuration: 0))
        cell.clear()
        await pool.release(item: candidate)
        await pool.stop()
    }


    func testBitmapCostUsesActualPixelsRatherThanScreenScaledSnapshotMetadata() throws {
        let artwork = pipelineBitmap(width: 64, height: 32)
        let bitmap = try XCTUnwrap(PreparedArtwork.bitmap(artwork))
        XCTAssertEqual(bitmap.width, 64)
        XCTAssertEqual(bitmap.height, 32)
        XCTAssertEqual(ImageCache.byteCost(of: artwork), bitmap.bytesPerRow * bitmap.height)
        let prepared = PreparedArtwork.image(bitmap)
        XCTAssertTrue(prepared.representations.allSatisfy { $0 is NSBitmapImageRep })
        XCTAssertEqual(ImageCache.byteCost(of: prepared), bitmap.bytesPerRow * bitmap.height)
    }

}
