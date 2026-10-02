import XCTest
import AppKit
@testable import MontageCore

/// Pure-logic unit tests (07-09 item 5): clamp math, grid auto-columns, cache
/// filename/URL normalization, and provider→model mapping.
final class PureLogicTests: XCTestCase {

    // MARK: - Title-reveal clamp (GridManager.resolveReveal)

    func testRevealDisabledWithoutHeadroom() {
        // rotationInterval - crossfade <= 0.3 → reveal disabled.
        let r = GridManager.resolveReveal(rotationInterval: 1.2, crossfadeDuration: 1.0,
                                          showTitleReveal: true, titleDisplayDuration: 2.0)
        XCTAssertFalse(r.show)
        XCTAssertEqual(r.duration, 0)
    }

    func testRevealDurationClampedToHeadroom() {
        let r = GridManager.resolveReveal(rotationInterval: 5.0, crossfadeDuration: 1.0,
                                          showTitleReveal: true, titleDisplayDuration: 10.0)
        XCTAssertTrue(r.show)
        XCTAssertEqual(r.duration, 4.0, accuracy: 1e-9)  // min(10, 5-1)
    }

    func testRevealRespectsDisableFlag() {
        let r = GridManager.resolveReveal(rotationInterval: 10, crossfadeDuration: 1,
                                          showTitleReveal: false, titleDisplayDuration: 2)
        XCTAssertFalse(r.show)
        XCTAssertEqual(r.duration, 0)
    }

    // MARK: - Auto grid columns (GridManager.autoColumns)

    func testAutoColumnsWidescreenFanart() {
        // 1920x1080, 2 rows, 16:9 → cell 960x540 → round(1920/960) = 2
        XCTAssertEqual(GridManager.autoColumns(width: 1920, height: 1080, rows: 2, targetAspect: 16.0/9.0), 2)
    }

    func testAutoColumnsPortraitPosters() {
        // 1080x1920, 3 rows, 2:3 → cell ~426.7x640 → round(1080/426.7) = 3
        XCTAssertEqual(GridManager.autoColumns(width: 1080, height: 1920, rows: 3, targetAspect: 2.0/3.0), 3)
    }

    func testAutoColumnsGuardsAndClamps() {
        XCTAssertEqual(GridManager.autoColumns(width: 0, height: 100, rows: 3, targetAspect: 1.77), 1)
        XCTAssertEqual(GridManager.autoColumns(width: 100, height: 100, rows: 0, targetAspect: 1.77),
                       GridManager.autoColumns(width: 100, height: 100, rows: 1, targetAspect: 1.77))
        let wide = GridManager.autoColumns(width: 100_000, height: 100, rows: 1, targetAspect: 16.0/9.0)
        XCTAssertGreaterThanOrEqual(wide, 1)
        XCTAssertLessThanOrEqual(wide, 20)
    }

    // MARK: - DiskCache filename + URL normalization

    func testDiskCacheFilenameDeterministic() {
        let a = DiskCache.filename(for: "/library/metadata/123/art")
        let b = DiskCache.filename(for: "/library/metadata/123/art")
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasSuffix(".jpg"))
        XCTAssertNotEqual(a, DiskCache.filename(for: "/library/metadata/999/art"))
    }

    func testNormalizeServerURL() {
        XCTAssertEqual(DiskCache.normalizeServerURL("https://HOST:32400/"), "https://host:32400")
        XCTAssertEqual(DiskCache.normalizeServerURL("  https://host:32400//  "), "https://host:32400")
        XCTAssertEqual(DiskCache.normalizeServerURL("https://host:32400"), "https://host:32400")
    }

    // MARK: - MediaItem art-path resolution + title key

    func testMediaItemArtPathAndTitleKey() {
        let item = MediaItem(id: "1", title: "The Matrix", year: 1999,
                             artPaths: [.fanart: "/f", .posters: "/p"])
        XCTAssertEqual(item.artPath(for: .fanart), "/f")
        XCTAssertEqual(item.artPath(for: .posters), "/p")
        XCTAssertEqual(item.titleKey, "the matrix|1999")

        let noYear = MediaItem(id: "2", title: "  Solo Title ", year: nil, artPaths: [:])
        XCTAssertEqual(noYear.titleKey, "solo title|")
    }

    func testMixedArtPathComesFromAvailablePaths() {
        let item = MediaItem(id: "1", title: "T", year: 2000, artPaths: [.fanart: "/f", .posters: "/p"])
        for _ in 0..<20 {
            let p = item.artPath(for: .mixed, includePostersInMixed: true)
            XCTAssertTrue(p == "/f" || p == "/p")
        }
    }

    func testMixedArtPathExcludesPostersByDefault() {
        let item = MediaItem(id: "1", title: "T", year: 2000, artPaths: [.fanart: "/f", .posters: "/p"])
        XCTAssertEqual(item.artPath(for: .mixed, includePostersInMixed: false), "/f")

        let posterOnly = MediaItem(id: "2", title: "Poster only", year: nil, artPaths: [.posters: "/p2"])
        XCTAssertNil(posterOnly.artPath(for: .mixed, includePostersInMixed: false))
    }

    func testMixedPoolHonorsPosterPreference() async {
        let items = [
            MediaItem(id: "1", title: "Fanart item", year: 2000, artPaths: [.fanart: "/f", .posters: "/p"]),
            MediaItem(id: "2", title: "Poster only", year: 2001, artPaths: [.posters: "/p2"])
        ]
        let provider = MockProvider(itemsByLibrary: ["lib": items])

        let defaultPool = ImagePool(provider: provider, imageSource: .mixed, includePostersInMixed: false,
                                    cellWidth: 4, cellHeight: 4, poolSize: 2,
                                    registry: ReservationRegistry())
        let defaultCount = await defaultPool.loadMediaItems(libraryIds: ["lib"])
        XCTAssertEqual(defaultCount, 1)

        let inclusivePool = ImagePool(provider: provider, imageSource: .mixed,
                                      includePostersInMixed: true,
                                      cellWidth: 4, cellHeight: 4, poolSize: 2,
                                      registry: ReservationRegistry())
        let inclusiveCount = await inclusivePool.loadMediaItems(libraryIds: ["lib"])
        XCTAssertEqual(inclusiveCount, 2)
    }

    // MARK: - Provider → MediaItem mapping

    func testPlexMediaItemConversion() throws {
        let json = Data("""
        {"ratingKey":"55","title":"Blade Runner","year":1982,
         "art":"/library/metadata/55/art/1","thumb":"/library/metadata/55/thumb/1"}
        """.utf8)
        let plex = try JSONDecoder().decode(PlexMediaItem.self, from: json)
        XCTAssertEqual(plex.artPath(for: .fanart), "/library/metadata/55/art/1")
        XCTAssertEqual(plex.artPath(for: .posters), "/library/metadata/55/thumb/1")

        let item = plex.toMediaItem()
        XCTAssertEqual(item.id, "55")
        XCTAssertEqual(item.title, "Blade Runner")
        XCTAssertEqual(item.year, 1982)
        XCTAssertEqual(item.artPaths[.fanart], "/library/metadata/55/art/1")
        XCTAssertEqual(item.artPaths[.posters], "/library/metadata/55/thumb/1")
    }

    func testPlexFanartFallsBackToGrandparentArt() throws {
        let json = Data("""
        {"ratingKey":"9","title":"Episode","grandparentArt":"/gp/art","grandparentThumb":"/gp/thumb"}
        """.utf8)
        let plex = try JSONDecoder().decode(PlexMediaItem.self, from: json)
        XCTAssertEqual(plex.artPath(for: .fanart), "/gp/art")
        XCTAssertEqual(plex.artPath(for: .posters), "/gp/thumb")
    }

    func testJellyfinItemConversion() throws {
        let json = Data("""
        {"Id":"abc","Name":"Dune","Type":"Movie","ProductionYear":2021,
         "ImageTags":{"Primary":"tag"},"BackdropImageTags":["bd0"]}
        """.utf8)
        let jf = try JSONDecoder().decode(JellyfinItem.self, from: json)
        let item = jf.toMediaItem()
        XCTAssertEqual(item.id, "abc")
        XCTAssertEqual(item.title, "Dune")
        XCTAssertEqual(item.year, 2021)
        XCTAssertEqual(item.artPaths[.posters], "/Items/abc/Images/Primary?tag=tag")
        XCTAssertEqual(item.artPaths[.fanart], "/Items/abc/Images/Backdrop/0?tag=bd0")
    }

    func testJellyfinItemWithoutBackdropHasNoFanart() throws {
        let json = Data("""
        {"Id":"x","Name":"NoArt","Type":"Movie","ImageTags":{"Primary":"t"}}
        """.utf8)
        let jf = try JSONDecoder().decode(JellyfinItem.self, from: json)
        let item = jf.toMediaItem()
        XCTAssertNil(item.artPaths[.fanart])
        XCTAssertEqual(item.artPaths[.posters], "/Items/x/Images/Primary?tag=t")
    }

    // MARK: - loadMediaItems dedupes by (title, year) — U5

    func testLoadMediaItemsDedupesByTitleYear() async {
        // Same movie in two libraries: same title/year, different ids/art paths.
        let dup1 = MediaItem(id: "a", title: "Inception", year: 2010, artPaths: [.fanart: "/hd/inception"])
        let dup2 = MediaItem(id: "b", title: "Inception", year: 2010, artPaths: [.fanart: "/4k/inception"])
        let unique = MediaItem(id: "c", title: "Arrival", year: 2016, artPaths: [.fanart: "/hd/arrival"])
        let provider = MockProvider(itemsByLibrary: ["movies": [dup1, unique], "movies4k": [dup2]])
        let pool = ImagePool(provider: provider, imageSource: .fanart,
                             cellWidth: 4, cellHeight: 4, poolSize: 4, diskCache: nil,
                             registry: ReservationRegistry())
        let count = await pool.loadMediaItems(libraryIds: ["movies", "movies4k"])
        XCTAssertEqual(count, 2, "the two Inception entries should collapse to one (title, year)")
    }
}
