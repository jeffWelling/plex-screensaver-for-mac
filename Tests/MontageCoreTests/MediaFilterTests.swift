import XCTest
import AppKit
@testable import MontageCore

private actor MetadataFixtureProvider: MediaProvider {
    nonisolated let serverName = "Fixture"
    nonisolated let filterCapabilities = ProviderType.plex.filterCapabilities
    private var requested: [String] = []
    func fetchLibraries() async throws -> [MediaLibrary] { [] }
    func fetchItems(libraryId: String) async throws -> [MediaItem] {
        try Task.checkCancellation()
        requested.append(libraryId)
        return [MediaItem(id: libraryId, title: libraryId, year: nil, artPaths: [:],
                          genres: [libraryId == "a" ? "Drama" : "Comedy"], collections: ["Collection \(libraryId)"])]
    }
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage { NSImage() }
    func requestedLibraries() -> [String] { requested }
}

final class MediaFilterTests: XCTestCase {
    func testOldCachedCatalogueDecodesWithoutMetadata() throws {
        let original = MediaItem(id: "x", title: "Old", year: 2000, artPaths: [.fanart: "/art"])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["genres", "collections", "isFavorite", "isWatched"] { object.removeValue(forKey: key) }
        let item = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(MediaFilter().matches(item))
        XCTAssertNil(item.isWatched)
        XCTAssertFalse(MediaFilter(unwatchedOnly: true).matches(item))
        XCTAssertFalse(MediaFilter(favoritesOnly: true).matches(item))
    }

    func testFilterCombinesCategoriesAndAcceptsAnySelectedValueWithinEach() {
        let item = MediaItem(id: "1", title: "One", year: nil, artPaths: [:],
                             genres: ["Science Fiction", "Drama"], collections: ["Classics"], isFavorite: true, isWatched: false)
        XCTAssertTrue(MediaFilter(genres: ["comedy", " science fiction "], collections: ["classics"], favoritesOnly: true, unwatchedOnly: true).matches(item))
        XCTAssertFalse(MediaFilter(genres: ["Science Fiction"], collections: ["Holiday"]).matches(item))
        XCTAssertFalse(MediaFilter(genres: ["Comedy"]).matches(item))
        XCTAssertEqual(MediaFilter(collections: ["Classics"]).filtered([item]).map(\.id), ["1"])
    }

    func testUnsupportedSelectionsAreRemovedForProvider() {
        let filter = MediaFilter(genres: ["Drama"], collections: ["Classics"], favoritesOnly: true, unwatchedOnly: true)
        XCTAssertTrue(filter.supported(by: .init()).isEmpty)
        let plex = filter.supported(by: ProviderType.plex.filterCapabilities)
        XCTAssertFalse(plex.favoritesOnly)
        XCTAssertEqual(plex.collections, ["Classics"])
        let jellyfin = filter.supported(by: ProviderType.jellyfin.filterCapabilities)
        XCTAssertTrue(jellyfin.favoritesOnly)
        XCTAssertTrue(jellyfin.collections.isEmpty)
        XCTAssertFalse(ProviderType.local.filterCapabilities.hasFilters)
    }

    func testChoicesAreTrimmedSortedAndDeduplicated() {
        let options = MediaFilterOptions(genres: [" Drama ", "drama", "", "Comedy"], collections: ["Été", "ete", "Classics"])
        XCTAssertEqual(options.genres, ["Comedy", "Drama"])
        XCTAssertEqual(options.collections.count, 2)
    }

    func testChoiceDiscoveryOnlyQueriesSelectedLibrariesOnce() async throws {
        let provider = MetadataFixtureProvider()
        let options = try await provider.fetchFilterOptions(libraryIds: ["a", "a"])
        XCTAssertEqual(options.genres, ["Drama"])
        XCTAssertEqual(options.collections, ["Collection a"])
        let requested = await provider.requestedLibraries()
        XCTAssertEqual(requested, ["a"])
        let empty = try await provider.fetchFilterOptions(libraryIds: [])
        XCTAssertEqual(empty, MediaFilterOptions())
    }

    func testPlexTagsAndUnplayedMovieConvertWithoutInventingFavorites() throws {
        let json = Data("""
        {"ratingKey":"1","title":"Movie","type":"movie","Genre":[{"tag":"Drama"}],"Collection":[{"tag":"Classics"}],"art":"/art"}
        """.utf8)
        let item = try JSONDecoder().decode(PlexMediaItem.self, from: json).toMediaItem()
        XCTAssertEqual(item.genres, ["Drama"])
        XCTAssertEqual(item.collections, ["Classics"])
        XCTAssertEqual(item.isWatched, false)
        XCTAssertNil(item.isFavorite)
        XCTAssertTrue(MediaFilter(collections: ["Classics"], unwatchedOnly: true).matches(item))
    }

    func testPartlyWatchedPlexSeriesRemainsUnwatched() throws {
        for (watchedEpisodes, expected) in [(0, false), (1, false), (10, true), (11, true)] {
            let json = Data("{\"ratingKey\":\"s\",\"title\":\"Series\",\"type\":\"show\",\"leafCount\":10,\"viewedLeafCount\":\(watchedEpisodes)}".utf8)
            let item = try JSONDecoder().decode(PlexMediaItem.self, from: json).toMediaItem()
            XCTAssertEqual(item.isWatched, expected)
            XCTAssertEqual(MediaFilter(unwatchedOnly: true).matches(item), !expected)
        }
        let unknown = try JSONDecoder().decode(PlexMediaItem.self, from: Data("{\"ratingKey\":\"s\",\"title\":\"Empty series\",\"type\":\"show\"}".utf8)).toMediaItem()
        XCTAssertNil(unknown.isWatched)
        XCTAssertTrue(MediaFilter().matches(unknown))
    }

    func testJellyfinGenreFavoriteAndWatchMetadataConvert() throws {
        let json = Data("""
        {"Id":"1","Name":"Movie","Type":"Movie","Genres":["Drama"],"UserData":{"IsFavorite":true,"Played":false}}
        """.utf8)
        let item = try JSONDecoder().decode(JellyfinItem.self, from: json).toMediaItem()
        XCTAssertEqual(item.genres, ["Drama"])
        XCTAssertEqual(item.isFavorite, true)
        XCTAssertEqual(item.isWatched, false)
        XCTAssertTrue(MediaFilter(genres: ["Drama"], favoritesOnly: true, unwatchedOnly: true).matches(item))
    }

    func testMetadataRoundTripsInDiskCatalogue() throws {
        let item = MediaItem(id: "x", title: "One", year: nil, artPaths: [:], genres: ["Drama"], collections: ["Classics"], isFavorite: true, isWatched: false)
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
        XCTAssertTrue(MediaFilter(genres: ["Drama"], collections: ["Classics"], favoritesOnly: true, unwatchedOnly: true).matches(decoded))
    }
}
