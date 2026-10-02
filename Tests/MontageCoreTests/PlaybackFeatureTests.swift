import XCTest
import AppKit
import QuartzCore
@testable import MontageCore

private actor PlaybackFixtureProvider: MediaProvider {
    nonisolated let serverName = "Playback fixture"
    private let items: [MediaItem]
    private let image: NSImage
    private var requests = 0
    private var catalogRequests = 0
    private let suspended: Bool
    private var continuation: CheckedContinuation<NSImage, Never>?
    init(items: [MediaItem], image: NSImage, suspended: Bool = false) {
        self.items = items; self.image = image; self.suspended = suspended
    }
    func fetchLibraries() async throws -> [MediaLibrary] { catalogRequests += 1; return [MediaLibrary(id: "library", name: "Library", type: "movies")] }
    func fetchItems(libraryId: String) async throws -> [MediaItem] { items }
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        requests += 1
        if suspended { return await withCheckedContinuation { continuation = $0 } }
        return image
    }
    func finishRequest() { continuation?.resume(returning: image); continuation = nil }
    var requestCount: Int { requests }
    var catalogCount: Int { catalogRequests }
}

final class PlaybackFeatureTests: XCTestCase {
    @MainActor private func bitmap() -> NSImage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 8, height: 8))
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    @MainActor private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<250 {
            if await condition() { return true }
            CATransaction.flush()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    func testMixedArtworkUsesCellShapeAndFallsBackWithoutChangingExplicitSource() {
        let item = MediaItem(id: "a", title: "Artwork", year: nil, artPaths: [.fanart: "/wide", .posters: "/portrait"])
        XCTAssertEqual(ArtworkSelection.path(for: item, source: .mixed, width: 160, height: 90), "/wide")
        XCTAssertEqual(ArtworkSelection.path(for: item, source: .mixed, width: 90, height: 160), "/portrait")
        XCTAssertEqual(ArtworkSelection.path(for: item, source: .posters, width: 160, height: 90), "/portrait")
        XCTAssertEqual(ArtworkSelection.path(for: item, source: .mixed, includePostersInMixed: false, width: 90, height: 160), "/wide")
        let onlyPoster = MediaItem(id: "b", title: "Poster", year: nil, artPaths: [.posters: "/poster"])
        XCTAssertEqual(ArtworkSelection.path(for: onlyPoster, source: .mixed, width: 160, height: 90), "/poster")
        XCTAssertNil(ArtworkSelection.path(for: onlyPoster, source: .fanart, width: 160, height: 90))
    }

    @MainActor func testFitCellPreservesContentsAspectAndBlackBackground() {
        let cell = GridCell(frame: CGRect(x: 0, y: 0, width: 160, height: 90), row: 0, column: 0, artworkFraming: .fit)
        XCTAssertTrue(cell.displayImage(bitmap(), transitionDuration: 0))
        XCTAssertTrue(cell.containerLayer.sublayers!.prefix(2).allSatisfy { $0.contentsGravity == .resizeAspect })
        XCTAssertEqual(cell.containerLayer.backgroundColor, CGColor.black)
        let fill = GridCell(frame: CGRect(x: 0, y: 0, width: 160, height: 90), row: 0, column: 0)
        XCTAssertTrue(fill.containerLayer.sublayers!.prefix(2).allSatisfy { $0.contentsGravity == .resizeAspectFill })
    }

    func testEnergyPolicyRestrictsOptionalWorkAndCriticalStatePausesEverything() {
        XCTAssertEqual(PlaybackRuntimePolicy.resolve(lowPower: false, thermalState: .nominal), .normal)
        let low = PlaybackRuntimePolicy.resolve(lowPower: true, thermalState: .nominal)
        XCTAssertEqual(low.prefetchLimit, 1); XCTAssertEqual(low.minimumRotationInterval, 15)
        XCTAssertGreaterThan(low.refreshInterval, PlaybackRuntimePolicy.normal.refreshInterval)
        XCTAssertEqual(PlaybackRuntimePolicy.resolve(lowPower: false, thermalState: .fair), low)
        let serious = PlaybackRuntimePolicy.resolve(lowPower: false, thermalState: .serious)
        XCTAssertFalse(serious.allowsNetwork); XCTAssertFalse(serious.pausesPlayback)
        let critical = PlaybackRuntimePolicy.resolve(lowPower: true, thermalState: .critical)
        XCTAssertTrue(critical.pausesPlayback); XCTAssertFalse(critical.allowsNetwork)
    }

    @MainActor func testLowPowerLimitsPrefillAndGridTimerThenRestoresUserTiming() async {
        let provider = PlaybackFixtureProvider(items: makeItems(10), image: bitmap())
        let pool = ImagePool(provider: provider, namespace: UUID().uuidString, imageSource: .fanart, cellWidth: 8, cellHeight: 8, poolSize: 8)
        _ = await pool.loadMediaItems(selection: .all)
        let low = PlaybackRuntimePolicy.resolve(lowPower: true, thermalState: .nominal)
        await pool.updateRuntimePolicy(low)
        let count = await pool.prefill()
        XCTAssertEqual(count, 1)
        let requests = await provider.requestCount
        XCTAssertEqual(requests, 1)
        let grid = GridManager(frame: CGRect(x: 0, y: 0, width: 160, height: 90), rows: 1, columns: 1, rotationInterval: 5)
        grid.updateRuntimePolicy(low); grid.startRotation(imagePool: pool)
        XCTAssertEqual(grid.scheduledRotationInterval, 15)
        grid.updateRuntimePolicy(.normal)
        XCTAssertEqual(grid.scheduledRotationInterval, 5)
        grid.stopRotation(); await pool.stop()
    }

    @MainActor func testCriticalPolicyCancelsLateNetworkResultAndBlocksNewRequests() async {
        let provider = PlaybackFixtureProvider(items: makeItems(5), image: bitmap(), suspended: true)
        let pool = ImagePool(provider: provider, namespace: UUID().uuidString, imageSource: .fanart, cellWidth: 8, cellHeight: 8, poolSize: 2)
        _ = await pool.loadMediaItems(selection: .all)
        let pending = Task { await pool.prefill() }
        let requested = await waitUntil { await provider.requestCount == 1 }
        XCTAssertTrue(requested)
        await pool.updateRuntimePolicy(.resolve(lowPower: false, thermalState: .critical))
        await provider.finishRequest()
        _ = await pending.value
        let stats = await pool.stats(); XCTAssertEqual(stats.poolDepth, 0)
        let blocked = await pool.takeImage(); XCTAssertNil(blocked)
        _ = await pool.loadMediaItems(selection: .all); _ = await pool.prefill()
        let requests = await provider.requestCount; let catalogs = await provider.catalogCount
        XCTAssertEqual(requests, 1); XCTAssertEqual(catalogs, 1)
        await pool.stop()
    }

    @MainActor func testCriticalGridKeepsArtworkAndReservationsWithoutRotation() async {
        let registry = ReservationRegistry()
        let provider = PlaybackFixtureProvider(items: makeItems(5), image: bitmap())
        let pool = ImagePool(provider: provider, namespace: UUID().uuidString, imageSource: .fanart, cellWidth: 8, cellHeight: 8, poolSize: 3, registry: registry)
        _ = await pool.loadMediaItems(selection: .all); _ = await pool.prefill()
        let grid = GridManager(frame: CGRect(x: 0, y: 0, width: 160, height: 90), rows: 1, columns: 1, rotationInterval: 5)
        grid.startRotation(imagePool: pool)
        let filled = await waitUntil { grid.occupiedCellCount == 1 }; XCTAssertTrue(filled)
        grid.rotateWeightedRandomCell()
        let staged = await waitUntil { grid.reservationCount == 2 }; XCTAssertTrue(staged)
        grid.updateRuntimePolicy(.resolve(lowPower: false, thermalState: .critical))
        let released = await waitUntil { await registry.count == 1 }; XCTAssertTrue(released)
        XCTAssertEqual(grid.occupiedCellCount, 1); XCTAssertNil(grid.scheduledRotationInterval)
        XCTAssertEqual(grid.cells[0].containerLayer.sublayers!.prefix(2).filter { $0.contents != nil }.count, 1)
        grid.rotateWeightedRandomCell(); XCTAssertEqual(grid.reservationCount, 1)
        grid.updateRuntimePolicy(.normal); XCTAssertEqual(grid.scheduledRotationInterval, 5)
        grid.stopRotation(); await pool.stop()
    }

    @MainActor func testSleepingDisplayOnlyResumesIfHostStillWantsAnimation() throws {
        let baseline = InstanceTracker.shared.activeCount
        let view = try XCTUnwrap(MontageView(frame: CGRect(x: 0, y: 0, width: 640, height: 360), isPreview: true))
        view.startAnimation(); XCTAssertEqual(InstanceTracker.shared.activeCount, baseline + 1)
        view.screensDidSleep(); XCTAssertEqual(InstanceTracker.shared.activeCount, baseline)
        XCTAssertEqual(view.layer?.sublayers?.count ?? 0, 0)
        view.screensDidWake(); XCTAssertEqual(InstanceTracker.shared.activeCount, baseline + 1)
        view.screensDidSleep(); view.stopAnimation(); view.screensDidWake()
        XCTAssertEqual(InstanceTracker.shared.activeCount, baseline)
        XCTAssertEqual(view.layer?.sublayers?.count ?? 0, 0)
        view.screensDidSleep(); view.startAnimation()
        XCTAssertEqual(InstanceTracker.shared.activeCount, baseline)
        view.screensDidWake(); XCTAssertEqual(InstanceTracker.shared.activeCount, baseline + 1)
        view.stopAnimation()
    }

    func testHistoryPersistsHashedIdentitiesAndKeepsAccountsSeparate() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = RecentTitleHistory(namespace: "account-a", directory: directory)
        await first.recordDisplayed(titleKey: "Private Movie|2026")
        let reopened = RecentTitleHistory(namespace: "account-a", directory: directory)
        let dates = await reopened.dates()
        XCTAssertEqual(dates.count, 1); XCTAssertNotNil(dates[RecentTitleHistory.digest("Private Movie|2026")])
        let other = RecentTitleHistory(namespace: "account-b", directory: directory)
        let otherDates = await other.dates(); XCTAssertTrue(otherDates.isEmpty)
        let file = directory.appendingPathComponent(RecentTitleHistory.digest("account-a")).appendingPathComponent("history.json")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("Private Movie"))
    }

    func testHistoryExpiresAndCapsEntries() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = RecentTitleHistory(namespace: "account", directory: directory, now: { now.addingTimeInterval(-RecentTitleHistory.maxAge - 1) })
        await old.recordDisplayed(titleKey: "old")
        let current = RecentTitleHistory(namespace: "account", directory: directory, now: { now })
        let expired = await current.dates(); XCTAssertTrue(expired.isEmpty)
        for index in 0..<(RecentTitleHistory.maxEntries + 20) { await current.recordDisplayed(titleKey: "title-\(index)") }
        let dates = await current.dates(); XCTAssertEqual(dates.count, RecentTitleHistory.maxEntries)
    }

    func testIndependentHistoryWritersDoNotLoseOneAnothersEntries() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = RecentTitleHistory(namespace: "account", directory: directory)
        let b = RecentTitleHistory(namespace: "account", directory: directory)
        async let left: Void = a.recordDisplayed(titleKey: "left")
        async let right: Void = b.recordDisplayed(titleKey: "right")
        _ = await (left, right)
        let dates = await a.dates(); XCTAssertEqual(dates.count, 2)
    }

    @MainActor func testHistoryPrefersUnseenTitlesAndRecordsOnlyConfirmedDisplays() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let history = RecentTitleHistory(namespace: "account", directory: directory)
        let items = makeItems(6)
        for item in items.dropLast() { await history.recordDisplayed(titleKey: item.titleKey) }
        let provider = PlaybackFixtureProvider(items: items, image: bitmap())
        let pool = ImagePool(provider: provider, namespace: "account", imageSource: .fanart, cellWidth: 8, cellHeight: 8, poolSize: 1, recentHistory: history)
        _ = await pool.loadMediaItems(selection: .all); _ = await pool.prefill()
        let taken = await pool.takeImage(); let item = try XCTUnwrap(taken)
        XCTAssertEqual(item.titleKey, items.last?.titleKey)
        let before = await history.dates(); XCTAssertNil(before[RecentTitleHistory.digest(item.titleKey)])
        await pool.didDisplay(item)
        let after = await history.dates(); XCTAssertNotNil(after[RecentTitleHistory.digest(item.titleKey)])
        await pool.stop()
    }

    @MainActor func testHistoryNeverStarvesTinyLibraries() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let history = RecentTitleHistory(namespace: "small", directory: directory)
        let item = makeItems(1)[0]; await history.recordDisplayed(titleKey: item.titleKey)
        let provider = PlaybackFixtureProvider(items: [item], image: bitmap())
        let pool = ImagePool(provider: provider, namespace: "small", imageSource: .fanart, cellWidth: 8, cellHeight: 8, poolSize: 1, recentHistory: history)
        _ = await pool.loadMediaItems(selection: .all)
        let count = await pool.prefill(); XCTAssertEqual(count, 1)
        let taken = await pool.takeImage(); XCTAssertNotNil(taken)
        await pool.stop()
    }

    @MainActor func testPreviewReservationScopeDoesNotBlockProductionArtwork() async throws {
        let registry = ReservationRegistry()
        let provider = PlaybackFixtureProvider(items: makeItems(1), image: bitmap())
        let normal = ImagePool(provider: provider, namespace: "same-account", imageSource: .fanart, cellWidth: 8, cellHeight: 8, poolSize: 1, registry: registry)
        let preview = ImagePool(provider: provider, namespace: "same-account", imageSource: .fanart, cellWidth: 8, cellHeight: 8, poolSize: 1, registry: registry, reservationNamespace: "same-account.preview")
        _ = await normal.loadMediaItems(selection: .all); _ = await normal.prefill()
        _ = await preview.loadMediaItems(selection: .all); _ = await preview.prefill()
        let liveItem = await normal.takeImage(); let previewItem = await preview.takeImage()
        XCTAssertNotNil(liveItem); XCTAssertNotNil(previewItem)
        let count = await registry.count; XCTAssertEqual(count, 2)
        await normal.stop(); await preview.stop()
    }

    @MainActor func testCachedStartupPrefersUnseenTitleBeforeDecodingQueue() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let history = RecentTitleHistory(namespace: "account", directory: directory)
        let cache = DiskCache(namespace: "account", directory: directory.appendingPathComponent("cache"))
        let items = makeItems(5)
        for item in items { await cache.store(item.artPaths[.fanart]!, image: bitmap(), item: item, source: .fanart, width: 8, height: 8) }
        for item in items.dropFirst() { await history.recordDisplayed(titleKey: item.titleKey) }
        let provider = PlaybackFixtureProvider(items: items, image: bitmap())
        let pool = ImagePool(provider: provider, namespace: "account", imageSource: .fanart, cellWidth: 8, cellHeight: 8, poolSize: 1, diskCache: cache, recentHistory: history)
        let count = await pool.restoreCachedImages(selection: .all); XCTAssertEqual(count, 1)
        let taken = await pool.takeImage(); XCTAssertEqual(taken?.titleKey, items.first?.titleKey)
        let requests = await provider.requestCount; XCTAssertEqual(requests, 0)
        await pool.stop()
    }
    @MainActor func testOfflineCatalogueRotatesBeyondDecodedQueueAndUsesStoredRevisionPath() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = DiskCache(namespace: "offline", directory: directory)
        let items = makeItems(12)
        for item in items { await cache.store(item.artPaths[.fanart]!, image: bitmap(), item: item, source: .fanart, width: 8, height: 8) }
        // Metadata refresh must not turn old but usable JPEGs into unreachable files.
        let updated = items.map { MediaItem(id: $0.id, title: $0.title, year: $0.year,
            artPaths: [.fanart: "/new-revision/" + $0.id], libraryId: "library") }
        // Fixture cache entries need a library to participate in metadata refresh.
        for item in items {
            var tagged = item; tagged.libraryId = "library"
            await cache.store(item.artPaths[.fanart]!, image: bitmap(), item: tagged, source: .fanart, width: 8, height: 8)
        }
        await cache.refreshMetadata(updated, libraryIDs: ["library"])
        let provider = PlaybackFixtureProvider(items: [], image: bitmap())
        let pool = ImagePool(provider: provider, namespace: "offline", imageSource: .fanart, cellWidth: 8, cellHeight: 8, poolSize: 2, diskCache: cache)
        await pool.updateRuntimePolicy(.resolve(lowPower: false, thermalState: .serious))
        let restored = await pool.restoreCachedImages(selection: .all); XCTAssertEqual(restored, 2)
        let catalogueCount = await pool.catalogueItemCount; XCTAssertEqual(catalogueCount, 12)
        var shown = Set<String>()
        for _ in 0..<20 {
            _ = await pool.prefill()
            if let item = await pool.takeImage() { shown.insert(item.titleKey); await pool.release(item: item) }
            if shown.count > 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(shown.count, 2, "offline playback must reach artwork outside the initial two decoded candidates")
        let requests = await provider.requestCount; XCTAssertEqual(requests, 0)
        await pool.stop()
    }

    @MainActor func testDraftPreviewUsesStagedLayoutWithoutSavingPreferences() throws {
        let original = Preferences.settingsSnapshot()
        let view = try XCTUnwrap(MontageView(frame: CGRect(x: 0, y: 0, width: 640, height: 360), isPreview: true))
        let connection = ConnectionSnapshot(provider: .local, serverURL: "", token: "", userID: "", accountID: "")
        let draft = SaverSettings(rows: 2, columns: 3, autoColumns: false, rotationInterval: 5,
            imageSource: .fanart, showTitleReveal: false, titleDisplayDuration: 2, librarySelection: .all)
        view.configurePreview(settings: draft, connection: connection); view.startAnimation()
        XCTAssertEqual(view.layer?.sublayers?.first?.sublayers?.count, 6)
        let next = SaverSettings(rows: 1, columns: 1, autoColumns: false, rotationInterval: 60,
            imageSource: .fanart, showTitleReveal: false, titleDisplayDuration: 2, librarySelection: .all)
        view.configurePreview(settings: next, connection: connection)
        XCTAssertEqual(view.layer?.sublayers?.first?.sublayers?.count, 1)
        view.stopAnimation()
        XCTAssertEqual(Preferences.settingsSnapshot(), original)
    }

}
