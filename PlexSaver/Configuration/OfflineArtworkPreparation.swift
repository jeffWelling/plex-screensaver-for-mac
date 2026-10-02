import AppKit

/// Counts titles rather than image variants, and only counts artwork that can
/// satisfy the selected libraries, source, filters, and display dimensions.
struct OfflineArtworkReadiness: Equatable, Sendable {
    var readyTitles: Int
    var lastPreparedDate: Date?
    static let empty = OfflineArtworkReadiness(readyTitles: 0, lastPreparedDate: nil)
}
struct OfflineArtworkProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
    let downloaded: Int
}
struct OfflineArtworkPreparationResult: Equatable, Sendable {
    let checked: Int
    let downloaded: Int
    let failed: Int
    let limited: Bool
    var matchingTitles: Int? = nil
    var alreadyPrepared = false
    var message: String {
        if matchingTitles == 0 { return "No artwork matches the selected libraries and filters." }
        if alreadyPrepared, let matchingTitles { return "All \(matchingTitles) selected titles are already prepared for offline playback." }
        let suffix = limited ? " Preparation is limited to 200 titles per run; run it again to continue." : ""
        if failed > 0 { return "Checked \(checked) titles · \(downloaded) images downloaded · \(failed) unavailable. Existing artwork was kept.\(suffix)" }
        return "Checked \(checked) titles · \(downloaded) images downloaded.\(suffix)"
    }
}
protocol OfflineArtworkPreparing: Sendable {
    func readiness(connection: ConnectionSnapshot, settings: SaverSettings, width: Int, height: Int) async -> OfflineArtworkReadiness
    func prepare(connection: ConnectionSnapshot, settings: SaverSettings, width: Int, height: Int,
                 refreshExisting: Bool, progress: @escaping @Sendable (OfflineArtworkProgress) async -> Void) async throws -> OfflineArtworkPreparationResult
}

enum ConfigurationProviderFactory {
    static func make(connection: ConnectionSnapshot) throws -> any MediaProvider {
        switch connection.provider {
        case .plex: return PlexProvider(serverURL: connection.serverURL, token: connection.token, fallbackURLs: connection.fallbackURLs)
        case .jellyfin: return JellyfinProvider(serverURL: connection.serverURL, accessToken: connection.token, userId: connection.userID)
        case .local:
            guard let bookmark = connection.localFolderBookmark else { throw OfflinePreparationError.noFolder }
            return try LocalArtworkProvider(bookmarkData: bookmark)
        }
    }
}
private enum OfflinePreparationError: LocalizedError {
    case noFolder, cacheWriteFailed
    var errorDescription: String? {
        switch self {
        case .noFolder: return "Choose an artwork folder first."
        case .cacheWriteFailed: return "The artwork could not be saved to the offline cache."
        }
    }
}

/// Sequential downloads bound memory and network use. A successful replacement
/// is written atomically by DiskCache; failed or canceled refreshes never clear
/// previous artwork. The selected connection is immutable for the whole run.
struct OfflineArtworkPreparation: OfflineArtworkPreparing {
    typealias ProviderFactory = @Sendable (ConnectionSnapshot) throws -> any MediaProvider
    typealias CacheFactory = @Sendable (String) async -> DiskCache
    typealias DimensionResolver = @Sendable (SaverSettings, Int, Int, Int) async -> (width: Int, height: Int)
    private let makeProvider: ProviderFactory
    private let makeCache: CacheFactory
    private let maximumTitles: Int
    private let resolveDimensions: DimensionResolver

    init(maximumTitles: Int = 200,
         makeProvider: @escaping ProviderFactory = { try ConfigurationProviderFactory.make(connection: $0) },
         makeCache: @escaping CacheFactory = { namespace in await OfflineArtworkPreparation.sharedCache(namespace) },
         resolveDimensions: @escaping DimensionResolver = { _, _, width, height in (width, height) }) {
        self.maximumTitles = max(1, min(200, maximumTitles))
        self.makeProvider = makeProvider; self.makeCache = makeCache; self.resolveDimensions = resolveDimensions
    }
    static func sharedCache(_ namespace: String) async -> DiskCache { await DiskCacheCoordinator.shared.cache(for: namespace) }
    static func forConnectedDisplays() -> OfflineArtworkPreparation {
        OfflineArtworkPreparation(resolveDimensions: { settings, count, width, height in
            await MainActor.run { ConfigurationDisplayDimensions.requestDimensions(settings: settings, availableItems: count, fallback: (width, height)) }
        })
    }
    func readiness(connection: ConnectionSnapshot, settings: SaverSettings, width: Int, height: Int) async -> OfflineArtworkReadiness {
        let cache = await makeCache(connection.profile.namespace)
        let filter = settings.mediaFilter.supported(by: connection.provider.filterCapabilities)
        let known = await cache.availableArtwork(selection: settings.librarySelection, imageSource: settings.imageSource,
            filter: filter, width: 1, height: 1, requireAdequateSize: false)
        let dimensions = await resolveDimensions(settings, known.count, width, height)
        let artwork = await cache.availableArtwork(selection: settings.librarySelection, imageSource: settings.imageSource,
            filter: filter, width: dimensions.width, height: dimensions.height)
        let summary = await cache.summary()
        return OfflineArtworkReadiness(readyTitles: artwork.count, lastPreparedDate: summary.lastPreparedDate)
    }
    func prepare(connection: ConnectionSnapshot, settings: SaverSettings, width: Int, height: Int,
                 refreshExisting: Bool, progress: @escaping @Sendable (OfflineArtworkProgress) async -> Void) async throws -> OfflineArtworkPreparationResult {
        try Task.checkCancellation()
        let provider = try makeProvider(connection)
        let cache = await makeCache(connection.profile.namespace)
        let libraryIDs: [String]
        switch settings.librarySelection {
        case .all: libraryIDs = try await provider.fetchLibraries().map(\.id)
        case .selected(let ids): libraryIDs = ids.sorted()
        }
        var items: [MediaItem] = []
        for library in libraryIDs {
            try Task.checkCancellation()
            var fetched = try await provider.fetchItems(libraryId: library)
            try Task.checkCancellation()
            for index in fetched.indices { fetched[index].libraryId = library }
            await cache.refreshMetadata(fetched, libraryIDs: [library])
            items.append(contentsOf: fetched)
        }
        let filter = settings.mediaFilter.supported(by: provider.filterCapabilities)
        var seen = Set<String>()
        let matching = items.filter { filter.matches($0) && artwork(for: $0, source: settings.imageSource, width: width, height: height) != nil && seen.insert($0.titleKey).inserted }
        let dimensions = await resolveDimensions(settings, matching.count, width, height)
        let requestWidth = dimensions.width, requestHeight = dimensions.height
        // Already prepared titles sort last, so bounded repeated runs progress
        // through a large library rather than fetching its first 200 forever.
        let available = await cache.availableArtwork(selection: settings.librarySelection, imageSource: settings.imageSource,
            filter: filter, width: requestWidth, height: requestHeight)
        var readyVariants = available
        if settings.imageSource == .mixed {
            let backgrounds = await cache.availableArtwork(selection: settings.librarySelection, imageSource: .fanart, filter: filter, width: requestWidth, height: requestHeight)
            let posters = await cache.availableArtwork(selection: settings.librarySelection, imageSource: .posters, filter: filter, width: requestWidth, height: requestHeight)
            readyVariants = backgrounds + posters
        }
        let readyPaths = Set(readyVariants.map(\.artPath))
        let ready = Set(matching.filter { item in artworkVariants(for: item, source: settings.imageSource, width: requestWidth, height: requestHeight).allSatisfy { readyPaths.contains($0.path) } }.map(\.titleKey))
        let dates = Dictionary(uniqueKeysWithValues: available.map { ($0.item.titleKey, $0.downloadedAt) })
        let batch = refreshExisting ? matching : matching.filter { !ready.contains($0.titleKey) }
        let candidates = batch.sorted {
            if ready.contains($0.titleKey) != ready.contains($1.titleKey) { return !ready.contains($0.titleKey) }
            let first = dates[$0.titleKey] ?? .distantPast, second = dates[$1.titleKey] ?? .distantPast
            return first == second ? $0.titleKey < $1.titleKey : first < second
        }
        var completed = 0, downloaded = 0, failed = 0
        for item in candidates.prefix(maximumTitles) {
            try Task.checkCancellation()
            for art in artworkVariants(for: item, source: settings.imageSource, width: requestWidth, height: requestHeight) {
                try Task.checkCancellation()
                if refreshExisting || !readyPaths.contains(art.path) {
                    do {
                        let image = try await provider.fetchImage(path: art.path, width: requestWidth, height: requestHeight)
                        try Task.checkCancellation()
                        let stored = await cache.store(art.path, image: image, item: item, source: art.source, width: requestWidth, height: requestHeight)
                        try Task.checkCancellation()
                        guard stored else { throw OfflinePreparationError.cacheWriteFailed }
                        downloaded += 1
                    } catch {
                        try Task.checkCancellation()
                        failed += 1
                    }
                }
            }
            completed += 1
            await progress(OfflineArtworkProgress(completed: completed, total: min(maximumTitles, candidates.count), downloaded: downloaded))
        }
        try Task.checkCancellation()
        if failed == 0 { await cache.markPreparationCompleted() }
        return OfflineArtworkPreparationResult(checked: completed, downloaded: downloaded, failed: failed, limited: candidates.count > maximumTitles,
            matchingTitles: matching.count, alreadyPrepared: !refreshExisting && !matching.isEmpty && candidates.isEmpty)
    }
    private func artwork(for item: MediaItem, source: ImageSourceType, width: Int, height: Int) -> (path: String, source: ImageSourceType)? {
        guard let path = ArtworkSelection.path(for: item, source: source, width: width, height: height) else { return nil }
        if source != .mixed { return (path, source) }
        let preferred: ImageSourceType = width >= height ? .fanart : .posters
        return (path, item.artPaths[preferred] == path ? preferred : (preferred == .fanart ? .posters : .fanart))
    }
    private func artworkVariants(for item: MediaItem, source: ImageSourceType, width: Int, height: Int) -> [(path: String, source: ImageSourceType)] {
        guard let preferred = artwork(for: item, source: source, width: width, height: height) else { return [] }
        guard source == .mixed else { return [preferred] }
        let alternate: ImageSourceType = preferred.source == .posters ? .fanart : .posters
        if let path = item.artPaths[alternate], path != preferred.path { return [preferred, (path, alternate)] }
        return [preferred]
    }

}


/// Uses each display's actual layout and backing scale. A small collection may
/// reduce the grid, so preparation must request the resulting larger cells.
@MainActor enum ConfigurationDisplayDimensions {
    static func requestDimensions(settings: SaverSettings, availableItems: Int? = nil,
                                  fallback: (width: Int, height: Int) = (960, 540)) -> (width: Int, height: Int) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return fallback }
        let dimensions = screens.map { screen in
            let nominalColumns = settings.autoColumns ? GridManager.autoColumns(width: screen.frame.width, height: screen.frame.height,
                rows: settings.rows, targetAspect: settings.imageSource == .posters ? 2.0 / 3.0 : 16.0 / 9.0) : settings.columns
            let layout = availableItems.map { GridManager.adaptiveDimensions(rows: settings.rows, columns: nominalColumns,
                availableItems: $0, displayCount: screens.count) } ?? (rows: settings.rows, columns: nominalColumns)
            return (width: min(8192, max(1, Int(screen.frame.width * screen.backingScaleFactor / CGFloat(layout.columns)))),
                    height: min(8192, max(1, Int(screen.frame.height * screen.backingScaleFactor / CGFloat(layout.rows)))))
        }
        return (dimensions.map(\.width).max() ?? fallback.width, dimensions.map(\.height).max() ?? fallback.height)
    }
}
