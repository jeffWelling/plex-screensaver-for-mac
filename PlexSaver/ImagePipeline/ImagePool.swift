//
//  ImagePool.swift
//  PlexSaver
//

import AppKit
import os.log

struct ImageWithMetadata {
    let artPath: String
    let image: NSImage
    let title: String
    let year: Int?
    /// `(title, year)` identity key for title-level uniqueness (U5).
    let titleKey: String
}

/// Process-wide reservation of media identity. Multiple `ImagePool` instances
/// run concurrently on multi-monitor setups (one per `MontageView`); delegating
/// reservation to this shared actor prevents the same media from appearing on
/// two monitors at the same moment.
///
/// Two independent constraints are enforced (U5, title-level uniqueness):
/// `artPath` (never the same artwork twice) and `titleKey` (never the same movie
/// twice, even as poster on one screen and fanart on another, or the same title
/// drawn from two libraries). A reservation succeeds only if both are free and
/// releases both together. `titleKey` is optional: the cached Phase-1 path has
/// no titles, so it reserves on artwork alone.
actor ReservationRegistry {
    static let shared = ReservationRegistry()
    private var reservedArtPaths: Set<String> = []
    private var reservedTitleKeys: Set<String> = []

    /// Reserve `artPath` (and, when provided, `titleKey`) iff both are free.
    /// Returns true iff this call newly reserved them (caller must release).
    func reserve(artPath: String, titleKey: String? = nil) -> Bool {
        if reservedArtPaths.contains(artPath) { return false }
        if let titleKey, reservedTitleKeys.contains(titleKey) { return false }
        reservedArtPaths.insert(artPath)
        if let titleKey { reservedTitleKeys.insert(titleKey) }
        return true
    }

    func release(artPath: String, titleKey: String? = nil) {
        reservedArtPaths.remove(artPath)
        if let titleKey { reservedTitleKeys.remove(titleKey) }
    }

    /// Number of art paths currently reserved. Read-only; used by the debug HUD
    /// (A2) and the leak-detector test (A1).
    var count: Int { reservedArtPaths.count }
}

actor ImagePool {
    private let provider: any MediaProvider
    private let imageSource: ImageSourceType
    private let cellWidth: Int
    private let cellHeight: Int
    private let cache: ImageCache
    private let diskCache: DiskCache?

    private var mediaItems: [MediaItem] = []
    private var shuffledIndices: [Int] = []
    private var currentIndex = 0
    private var pool: [ImageWithMetadata] = []
    private let poolSize: Int
    private var isRefilling = false
    private var isStopped = false

    /// Consecutive failed fetches inside a single `refillPool()` pass before it
    /// backs off, and how long it waits before one more probe. Bounds retries so
    /// a dead server or fully-reserved library is not hammered, while still
    /// letting rotation recover within ~one retry interval of conditions
    /// improving.
    private static let maxRefillFailures = 3
    private static let refillRetryDelayNanos: UInt64 = 30 * 1_000_000_000
    /// Art paths this pool has reserved (via the registry) but not yet released,
    /// mapped to the title key reserved alongside each so both can be released
    /// together. Tracked locally so `stop()` can return every reservation on
    /// teardown — including paths held by on-screen cells, whose release is
    /// normally orchestrated by `GridManager`.
    private var reservedTitleKeyByArtPath: [String: String] = [:]

    init(provider: any MediaProvider, imageSource: ImageSourceType, cellWidth: Int, cellHeight: Int, poolSize: Int, diskCache: DiskCache? = nil) {
        self.provider = provider
        self.imageSource = imageSource
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.poolSize = poolSize
        self.cache = ImageCache(maxSize: poolSize * 2)
        self.diskCache = diskCache
    }

    /// Load media items from configured libraries. Returns count of items with art.
    @discardableResult
    func loadMediaItems(libraryIds: [String]) async -> Int {
        var allItems: [MediaItem] = []
        do {
            if libraryIds.isEmpty {
                // Fetch all libraries
                let libraries = try await provider.fetchLibraries()
                for library in libraries {
                    let items = try await provider.fetchItems(libraryId: library.id)
                    allItems.append(contentsOf: items)
                }
            } else {
                for id in libraryIds {
                    let items = try await provider.fetchItems(libraryId: id)
                    allItems.append(contentsOf: items)
                }
            }
        } catch {
            OSLog.info("ImagePool: Failed to load media items: \(error.localizedDescription)")
        }

        // Filter to items that have art for our source type, and dedupe by
        // title identity (U5): the same movie present in two libraries (e.g.
        // Movies + 4K) has different ids/art paths but is a visual duplicate, so
        // keep only the first occurrence of each (title, year).
        var seenTitleKeys = Set<String>()
        mediaItems = allItems.filter { item in
            guard item.artPath(for: imageSource) != nil else { return false }
            return seenTitleKeys.insert(item.titleKey).inserted
        }
        OSLog.info("ImagePool: Loaded \(mediaItems.count) media items with art")

        reshuffleIndices()
        return mediaItems.count
    }

    /// Pre-fill the pool with images. Returns count of images loaded.
    @discardableResult
    func prefill() async -> Int {
        guard !mediaItems.isEmpty else { return 0 }
        OSLog.info("ImagePool: Pre-filling pool with \(poolSize) images")

        for _ in 0..<poolSize {
            if isStopped { break }
            if let item = await fetchNextImage() {
                pool.append(item)
            }
        }

        OSLog.info("ImagePool: Pool pre-filled with \(pool.count) images")
        return pool.count
    }

    /// Take an image from the pool. Returns nil if pool is empty.
    func takeImage() -> ImageWithMetadata? {
        let item = pool.isEmpty ? nil : pool.removeFirst()

        // Trigger a background refill whenever the pool is low OR empty. The
        // check deliberately runs even on the empty path: a pool that drained to
        // empty (a network blip, or a moment where every unreserved path was
        // momentarily taken) must still schedule a refill so it can recover once
        // conditions improve, instead of freezing until the saver restarts.
        if pool.count < poolSize / 2 && !isRefilling && !isStopped {
            Task { await refillPool() }
        }

        return item
    }

    /// Stop all background activity. Returns every still-reserved art path to
    /// the shared registry so other screens / future sessions can pick them up.
    func stop() async {
        isStopped = true
        pool.removeAll()
        cache.clear()

        let held = reservedTitleKeyByArtPath
        reservedTitleKeyByArtPath.removeAll()
        for (artPath, titleKey) in held {
            await ReservationRegistry.shared.release(artPath: artPath, titleKey: titleKey)
        }
    }

    /// Release a previously-reserved art path (and its paired title key) so
    /// another cell can show it again. Called by `GridManager` after a cell's
    /// outgoing image is no longer visible.
    func release(artPath: String) async {
        let titleKey = reservedTitleKeyByArtPath.removeValue(forKey: artPath)
        await ReservationRegistry.shared.release(artPath: artPath, titleKey: titleKey)
    }

    // MARK: - Private

    private func reshuffleIndices() {
        shuffledIndices = Array(0..<mediaItems.count).shuffled()
        currentIndex = 0
    }

    /// Returns the next (item, artPath) pair whose path is not currently reserved,
    /// and reserves it via `ReservationRegistry.shared`. Resolves `artPath` once
    /// at pick time so that `.mixed` mode (which randomizes among available
    /// paths per call) stays consistent across the reservation's lifetime.
    /// Returns nil if every path covered by the library is already reserved
    /// (across all pools, not just this one).
    private func nextMediaItem() async -> (item: MediaItem, artPath: String)? {
        guard !mediaItems.isEmpty else { return nil }

        // Bounded: try at most one full pass through the library.
        var attempts = 0
        while attempts < mediaItems.count {
            if currentIndex >= shuffledIndices.count {
                reshuffleIndices()
            }

            let item = mediaItems[shuffledIndices[currentIndex]]
            currentIndex += 1
            attempts += 1

            guard let artPath = item.artPath(for: imageSource) else { continue }

            // Reserve on both artwork and title identity (U5).
            if await ReservationRegistry.shared.reserve(artPath: artPath, titleKey: item.titleKey) {
                reservedTitleKeyByArtPath[artPath] = item.titleKey
                return (item, artPath)
            }
        }

        return nil
    }

    private func fetchNextImage() async -> ImageWithMetadata? {
        guard let (item, artPath) = await nextMediaItem() else { return nil }
        // artPath (and its title key) are reserved from this point on.

        if let result = await loadImage(for: item, artPath: artPath) {
            return result
        }

        // Fetch failed — release the reservation so this item can be tried again.
        let titleKey = reservedTitleKeyByArtPath.removeValue(forKey: artPath)
        await ReservationRegistry.shared.release(artPath: artPath, titleKey: titleKey)
        return nil
    }

    private func loadImage(for item: MediaItem, artPath: String) async -> ImageWithMetadata? {
        // 1. Check in-memory cache
        if let cached = cache.get(artPath) {
            return ImageWithMetadata(artPath: artPath, image: cached, title: item.title, year: item.year, titleKey: item.titleKey)
        }

        // 2. Check disk cache
        if let disk = diskCache, let cached = await disk.get(artPath) {
            cache.set(artPath, image: cached)
            return ImageWithMetadata(artPath: artPath, image: cached, title: item.title, year: item.year, titleKey: item.titleKey)
        }

        // 3. Fetch from network, write-through to both caches
        do {
            let image = try await provider.fetchImage(path: artPath, width: cellWidth, height: cellHeight)
            cache.set(artPath, image: image)
            if let disk = diskCache {
                await disk.store(artPath, image: image)
            }
            return ImageWithMetadata(artPath: artPath, image: image, title: item.title, year: item.year, titleKey: item.titleKey)
        } catch {
            OSLog.info("ImagePool: Failed to fetch image for \(item.title): \(error.localizedDescription)")
            return nil
        }
    }

    private func refillPool() async {
        guard !isRefilling else { return }
        isRefilling = true
        defer { isRefilling = false }

        var consecutiveFailures = 0

        while pool.count < poolSize && !isStopped {
            if let item = await fetchNextImage() {
                pool.append(item)
                consecutiveFailures = 0
                continue
            }

            // A fetch failed — either a transient network error or a moment
            // where every unreserved art path is taken (small library / second
            // monitor). Don't `break` permanently (that was the freeze bug), but
            // don't spin hot either: after a few consecutive failures, back off
            // once. `isRefilling` stays true across the sleep, so `takeImage()`
            // won't spawn a parallel refill that hammers a dead server every
            // rotation tick. If the situation hasn't recovered after the delay,
            // exit this pass — the next `takeImage()` re-triggers a fresh refill.
            consecutiveFailures += 1
            if consecutiveFailures >= Self.maxRefillFailures {
                try? await Task.sleep(nanoseconds: Self.refillRetryDelayNanos)
                if isStopped { return }
                if let item = await fetchNextImage() {
                    pool.append(item)
                    consecutiveFailures = 0
                } else {
                    break
                }
            }
        }
    }
}
