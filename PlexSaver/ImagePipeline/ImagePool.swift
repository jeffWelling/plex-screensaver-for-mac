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

/// Read-only snapshot of a pool's state for the debug HUD (A2).
struct PoolStats {
    let poolDepth: Int
    let poolCapacity: Int
    let reservedByThisPool: Int
    let lastRefillResult: String
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

/// De-duplicates concurrent network image fetches for the same art path across
/// all pools (U4 tier 1). With reservation moved to display time, two monitors'
/// pools can independently hold the same art path and would otherwise each
/// download it; callers here share a single in-flight request keyed by art path.
/// The disk cache already stores one size per art path, so coalescing on the
/// path alone is consistent with what warm reads return.
actor ImageRequestCoalescer {
    static let shared = ImageRequestCoalescer()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    func image(for artPath: String, fetch: @Sendable @escaping () async -> NSImage?) async -> NSImage? {
        if let existing = inFlight[artPath] {
            return await existing.value
        }
        let task = Task { await fetch() }
        inFlight[artPath] = task
        let image = await task.value
        inFlight[artPath] = nil
        return image
    }
}

actor ImagePool {
    private let provider: any MediaProvider
    private let imageSource: ImageSourceType
    private let includePostersInMixed: Bool
    private let cellWidth: Int
    private let cellHeight: Int
    private let cache: ImageCache
    private let diskCache: DiskCache?
    /// Shared reservation registry (injectable so tests can drive a pool against
    /// an isolated registry instead of the process-wide singleton).
    private let registry: ReservationRegistry

    private var mediaItems: [MediaItem] = []
    private var shuffledIndices: [Int] = []
    private var currentIndex = 0
    private var pool: [ImageWithMetadata] = []
    private let poolSize: Int
    private var isRefilling = false
    private var isStopped = false
    /// Human-readable outcome of the most recent refill pass, for the debug HUD.
    private var lastRefillResult = "—"

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

    init(provider: any MediaProvider, imageSource: ImageSourceType, includePostersInMixed: Bool = false, cellWidth: Int, cellHeight: Int, poolSize: Int, diskCache: DiskCache? = nil, registry: ReservationRegistry = .shared) {
        self.provider = provider
        self.imageSource = imageSource
        self.includePostersInMixed = includePostersInMixed
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.poolSize = poolSize
        // Cap the in-memory cache by both count and bytes (N2): the byte budget
        // is the count limit expressed at this pool's cell resolution, so it
        // never shrinks below the pool's working set but does put a hard ceiling
        // on memory when images are larger than estimated.
        let bytesPerImage = max(1, cellWidth * cellHeight * 4)
        self.cache = ImageCache(countLimit: poolSize * 2, totalCostLimit: bytesPerImage * poolSize * 2)
        self.diskCache = diskCache
        self.registry = registry
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
                    var items = try await provider.fetchItems(libraryId: library.id)
                    for i in items.indices { items[i].libraryId = library.id }
                    allItems.append(contentsOf: items)
                }
            } else {
                for id in libraryIds {
                    var items = try await provider.fetchItems(libraryId: id)
                    for i in items.indices { items[i].libraryId = id }
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
            guard item.artPath(for: imageSource, includePostersInMixed: includePostersInMixed) != nil else { return false }
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

    /// Take an image from the pool, reserving its identity at display time
    /// (U4 tier 1). The pool holds *unreserved* candidates; pop until one whose
    /// art path AND title are both free across every cell/monitor can be
    /// reserved. Candidates that lose the reservation race are discarded (refill
    /// replenishes). Reservation pressure is therefore exactly what is on screen
    /// (cells × monitors), not on-screen + pooled — so a small library or a
    /// second monitor is never starved by another pool's pooled reservations,
    /// and no false "check server connection" error is shown for a healthy setup.
    /// Returns nil if nothing reservable is available.
    func takeImage() async -> ImageWithMetadata? {
        while !pool.isEmpty {
            let candidate = pool.removeFirst()
            triggerRefillIfNeeded()
            if await registry.reserve(artPath: candidate.artPath, titleKey: candidate.titleKey) {
                reservedTitleKeyByArtPath[candidate.artPath] = candidate.titleKey
                return candidate
            }
            // Already reserved elsewhere — drop it and try the next candidate.
        }
        triggerRefillIfNeeded()
        return nil
    }

    /// Schedule a background refill whenever the pool is low or empty. Runs even
    /// on the empty path so a pool that drained (network blip, or a burst of
    /// discarded already-reserved candidates) still recovers instead of freezing.
    private func triggerRefillIfNeeded() {
        if pool.count < poolSize / 2 && !isRefilling && !isStopped {
            Task { await refillPool() }
        }
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
            await registry.release(artPath: artPath, titleKey: titleKey)
        }
    }

    /// Release a previously-reserved art path (and its paired title key) so
    /// another cell can show it again. Called by `GridManager` after a cell's
    /// outgoing image is no longer visible.
    func release(artPath: String) async {
        let titleKey = reservedTitleKeyByArtPath.removeValue(forKey: artPath)
        await registry.release(artPath: artPath, titleKey: titleKey)
    }

    /// Read-only snapshot for the debug HUD (A2).
    func stats() -> PoolStats {
        PoolStats(poolDepth: pool.count, poolCapacity: poolSize,
                  reservedByThisPool: reservedTitleKeyByArtPath.count,
                  lastRefillResult: lastRefillResult)
    }

    // MARK: - Private

    private func reshuffleIndices() {
        shuffledIndices = Array(0..<mediaItems.count).shuffled()
        currentIndex = 0
    }

    /// Returns the next (item, artPath) pair to fetch into the pool. Under
    /// reserve-at-take (U4 tier 1) this does NOT reserve — the pool holds
    /// unreserved candidates and `takeImage()` reserves at display time.
    /// Resolves `artPath` once here so `.mixed` mode (which randomizes among
    /// available paths per call) is stable for this candidate's lifetime.
    private func nextMediaItem() -> (item: MediaItem, artPath: String)? {
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

            guard let artPath = item.artPath(for: imageSource, includePostersInMixed: includePostersInMixed) else { continue }
            return (item, artPath)
        }

        return nil
    }

    private func fetchNextImage() async -> ImageWithMetadata? {
        guard let (item, artPath) = nextMediaItem() else { return nil }
        return await loadImage(for: item, artPath: artPath)
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

        // 3. Fetch from network, coalesced across pools so two monitors racing
        // the same art path issue a single request (U4 — with reservation moved
        // to display time, pools no longer implicitly dedupe fetches). Then
        // write-through to both caches.
        let width = cellWidth
        let height = cellHeight
        let image = await ImageRequestCoalescer.shared.image(for: artPath) { [provider] in
            try? await provider.fetchImage(path: artPath, width: width, height: height)
        }
        guard let image = image else {
            OSLog.info("ImagePool: Failed to fetch image for \(item.title)")
            return nil
        }
        cache.set(artPath, image: image)
        if let disk = diskCache {
            await disk.store(artPath, image: image, libraryId: item.libraryId)
        }
        return ImageWithMetadata(artPath: artPath, image: image, title: item.title, year: item.year, titleKey: item.titleKey)
    }

    private func refillPool() async {
        guard !isRefilling else { return }
        isRefilling = true
        defer {
            isRefilling = false
            lastRefillResult = isStopped ? "stopped" : "\(pool.count)/\(poolSize)"
        }

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
