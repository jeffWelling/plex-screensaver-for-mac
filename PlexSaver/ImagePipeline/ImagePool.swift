import AppKit
import os.log

/// Ownership is tied to one display assignment, never to an artwork path.
/// Releasing an old or already released lease cannot affect a newer owner.
struct ReservationLease: Hashable, Sendable {
    let id: UUID
    let namespace: String
    let artPath: String
    let titleKey: String?
}

struct ImageWithMetadata {
    let artPath: String
    let image: NSImage
    let title: String
    let year: Int?
    let titleKey: String
    let libraryId: String?
    let lease: ReservationLease?

    init(artPath: String, image: NSImage, title: String, year: Int?, titleKey: String,
         libraryId: String? = nil, lease: ReservationLease? = nil) {
        self.artPath = artPath
        self.image = image
        self.title = title
        self.year = year
        self.titleKey = titleKey
        self.libraryId = libraryId
        self.lease = lease
    }

    func reserved(with lease: ReservationLease) -> ImageWithMetadata {
        ImageWithMetadata(artPath: artPath, image: image, title: title, year: year,
                          titleKey: titleKey, libraryId: libraryId, lease: lease)
    }
}

struct PoolStats: Sendable {
    let poolDepth: Int
    let poolCapacity: Int
    let reservedByThisPool: Int
    let lastRefillResult: String
    let queuedBytes: Int
    let queueByteLimit: Int
}

actor ReservationRegistry {
    static let shared = ReservationRegistry()
    private var leases: [UUID: ReservationLease] = [:]
    private var artwork: [String: UUID] = [:]
    private var titles: [String: UUID] = [:]

    func reserve(artPath: String, titleKey: String? = nil, namespace: String = "default") -> ReservationLease? {
        let art = "\(namespace)|\(artPath)"
        let title = titleKey.map { "\(namespace)|\($0)" }
        guard artwork[art] == nil, title.map({ titles[$0] == nil }) ?? true else { return nil }
        let lease = ReservationLease(id: UUID(), namespace: namespace, artPath: artPath, titleKey: titleKey)
        leases[lease.id] = lease
        artwork[art] = lease.id
        if let title { titles[title] = lease.id }
        return lease
    }

    func release(lease: ReservationLease) {
        guard leases[lease.id] == lease else { return }
        leases.removeValue(forKey: lease.id)
        let art = "\(lease.namespace)|\(lease.artPath)"
        if artwork[art] == lease.id { artwork.removeValue(forKey: art) }
        if let titleKey = lease.titleKey {
            let title = "\(lease.namespace)|\(titleKey)"
            if titles[title] == lease.id { titles.removeValue(forKey: title) }
        }
    }

    var count: Int { leases.count }
}

/// Namespace and size are part of identity. Each pool is a cancellable waiter;
/// stopping one monitor cannot cancel a download another monitor still needs.
actor ImageRequestCoalescer {
    static let shared = ImageRequestCoalescer()
    private struct Request {
        let id: UUID
        let task: Task<Result<NSImage, Error>, Never>
        var waiters: [UUID: UUID]
    }
    private var requests: [String: Request] = [:]

    func image(for key: String, owner: UUID,
               fetch: @Sendable @escaping () async throws -> NSImage) async throws -> NSImage {
        let waiter = UUID()
        let request: Request
        if var existing = requests[key] {
            existing.waiters[waiter] = owner
            requests[key] = existing
            request = existing
        } else {
            let task = Task<Result<NSImage, Error>, Never> {
                do { return .success(try await fetch()) } catch { return .failure(error) }
            }
            request = Request(id: UUID(), task: task, waiters: [waiter: owner])
            requests[key] = request
        }
        let result = await withTaskCancellationHandler(operation: {
            await request.task.value
        }, onCancel: {
            Task { await self.cancel(waiter: waiter, key: key) }
        })
        let stillRegistered = requests[key]?.id == request.id && requests[key]?.waiters[waiter] == owner
        if var current = requests[key], current.id == request.id {
            current.waiters.removeValue(forKey: waiter)
            if current.waiters.isEmpty { requests.removeValue(forKey: key) }
            else { requests[key] = current }
        }
        try Task.checkCancellation()
        guard stillRegistered else { throw CancellationError() }
        return try result.get()
    }

    #if DEBUG
    func activeWaiterCount(for key: String) -> Int { requests[key]?.waiters.count ?? 0 }
    #endif

    func cancel(owner: UUID) {
        for key in Array(requests.keys) {
            guard var request = requests[key] else { continue }
            request.waiters = request.waiters.filter { $0.value != owner }
            if request.waiters.isEmpty {
                request.task.cancel()
                requests.removeValue(forKey: key)
            } else { requests[key] = request }
        }
    }

    private func cancel(waiter: UUID, key: String) {
        guard var request = requests[key] else { return }
        request.waiters.removeValue(forKey: waiter)
        if request.waiters.isEmpty {
            request.task.cancel()
            requests.removeValue(forKey: key)
        } else { requests[key] = request }
    }
}

actor ImagePool {
    private let provider: any MediaProvider
    private let namespace: String
    private let imageSource: ImageSourceType
    private let includePostersInMixed: Bool
    private var cellWidth: Int
    private var cellHeight: Int
    private let cache: ImageCache
    private let diskCache: DiskCache?
    private let registry: ReservationRegistry
    private var owner = UUID()
    private let now: @Sendable () -> Date
    private let retryInterval: TimeInterval
    private var mediaItems: [MediaItem] = []
    private var shuffledIndices: [Int] = []
    private var currentIndex = 0
    private var pool: [ImageWithMetadata] = []
    static let queueByteLimit = 32 * 1_048_576
    private let requestedPoolSize: Int
    private var poolSize: Int
    private var queuedBytes = 0
    private var activeRefillID: UUID?
    private var isRefilling: Bool { activeRefillID != nil }
    private var isStopped = false
    private var lastRefillResult = "idle"
    private(set) var lastLoadError: MediaNetworkError?
    private var invalidArtworkPaths = Set<String>()
    private var leases: [UUID: ReservationLease] = [:]
    private var freshUntil: [String: Date] = [:]
    private var networkRetryAfter: Date?
    private var refillTask: Task<Void, Never>?
    private var refillTaskID: UUID?
    private var requestGeneration = 0
    private var librariesTask: Task<[MediaLibrary], Error>?
    private var itemsTask: Task<[MediaItem], Error>?
    private var catalogueGeneration = 0

    init(provider: any MediaProvider, namespace: String = "default", imageSource: ImageSourceType,
         includePostersInMixed: Bool = true, cellWidth: Int, cellHeight: Int,
         poolSize: Int, diskCache: DiskCache? = nil, registry: ReservationRegistry = .shared,
         retryInterval: TimeInterval = 30, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.namespace = namespace
        self.imageSource = imageSource
        self.includePostersInMixed = includePostersInMixed
        self.cellWidth = min(8192, max(1, cellWidth))
        self.cellHeight = min(8192, max(1, cellHeight))
        // Count is an early estimate; every enqueue also enforces actual decoded
        // bytes because aspect-fill artwork can exceed the requested cell area.
        self.requestedPoolSize = min(24, max(1, poolSize))
        let capacity = Self.capacity(width: self.cellWidth, height: self.cellHeight, requested: self.requestedPoolSize)
        self.poolSize = capacity
        self.cache = ImageCache(countLimit: max(4, capacity * 2), totalCostLimit: Self.queueByteLimit)
        self.diskCache = diskCache
        self.registry = registry
        self.retryInterval = retryInterval
        self.now = now
    }

    private static func capacity(width: Int, height: Int, requested: Int) -> Int {
        min(requested, max(1, queueByteLimit / (width * height * 4)))
    }

    /// Adopt larger adaptive cells without throwing away displayed reservations
    /// or queued offline fallback. Only unfinished old-size requests are revoked.
    func updateRequestSize(width: Int, height: Int) async {
        let width = min(8192, max(1, width))
        let height = min(8192, max(1, height))
        guard !isStopped, !Task.isCancelled, width != cellWidth || height != cellHeight else { return }
        let previousOwner = owner
        requestGeneration += 1
        owner = UUID()
        refillTask?.cancel()
        refillTask = nil
        refillTaskID = nil
        activeRefillID = nil
        cellWidth = width
        cellHeight = height
        poolSize = Self.capacity(width: width, height: height, requested: requestedPoolSize)
        // One old-size candidate keeps offline startup useful while allowing the
        // next dequeue to trigger replacement work at the new display resolution.
        if pool.count > 1 { pool = Array(pool.prefix(1)) }
        queuedBytes = pool.reduce(0) { $0 + ImageCache.byteCost(of: $1.image) }
        freshUntil.removeAll()
        cache.clear()
        lastRefillResult = "display size changed"
        await ImageRequestCoalescer.shared.cancel(owner: previousOwner)
    }

    private func activeRequest(_ generation: Int) -> Bool {
        !isStopped && !Task.isCancelled && requestGeneration == generation
    }

    @discardableResult
    private func enqueue(_ image: ImageWithMetadata) -> Bool {
        let cost = ImageCache.byteCost(of: image.image)
        guard cost > 0, cost <= Self.queueByteLimit, pool.count < poolSize,
              queuedBytes <= Self.queueByteLimit - cost else { return false }
        pool.append(image)
        queuedBytes += cost
        return true
    }

    /// Cached and network images enter the same queue and display-time lease
    /// system. Metadata is retained, including strict selected-library filtering.
    @discardableResult
    func restoreCachedImages(selection: LibrarySelection) async -> Int {
        guard !isStopped, !Task.isCancelled, let diskCache else { return 0 }
        let request = requestGeneration
        let cached = await diskCache.cachedImages(limit: poolSize, selection: selection,
                                                 imageSource: imageSource, includePostersInMixed: includePostersInMixed,
                                                 width: cellWidth, height: cellHeight,
                                                 decodedByteLimit: max(0, Self.queueByteLimit - queuedBytes))
        guard activeRequest(request) else { return 0 }
        var seen = Set(pool.map(\.titleKey))
        for record in cached where seen.insert(record.item.titleKey).inserted {
            guard pool.count < poolSize else { break }
            guard enqueue(candidate(record.item, artPath: record.artPath, image: record.image)) else { break }
        }
        mediaItems = cached.map(\.item)
        reshuffleIndices()
        lastRefillResult = "cached: \(pool.count)"
        return pool.count
    }

    @discardableResult
    func loadMediaItems(selection: LibrarySelection) async -> Int {
        guard !isStopped, !Task.isCancelled else { return 0 }
        catalogueGeneration += 1
        let generation = catalogueGeneration
        lastLoadError = nil
        librariesTask?.cancel()
        itemsTask?.cancel()
        var libraryIDs: [String]
        switch selection {
        case .all:
            let task = Task { [provider] in try await provider.fetchLibraries() }
            librariesTask = task
            do { libraryIDs = try await task.value.map(\.id) }
            catch {
                guard active(generation) else { return 0 }
                recordLoadError(error)
                return 0
            }
        case .selected(let ids): libraryIDs = ids.sorted()
        }
        guard active(generation) else { return 0 }
        let previousItems = mediaItems
        var allItems: [MediaItem] = []
        var failedLibraryIDs = Set<String>()
        var succeeded = libraryIDs.isEmpty
        for id in libraryIDs {
            guard active(generation) else { return 0 }
            let task = Task { [provider] in try await provider.fetchItems(libraryId: id) }
            itemsTask = task
            do {
                var items = try await task.value
                guard active(generation) else { return 0 }
                for index in items.indices { items[index].libraryId = id }
                allItems += items
                succeeded = true
            } catch {
                guard active(generation) else { return 0 }
                recordLoadError(error)
                failedLibraryIDs.insert(id)
                // A transient failure must not erase this library's known
                // catalogue while other libraries are refreshed successfully.
            }
        }
        let retained = previousItems.filter { item in
            item.libraryId.map { failedLibraryIDs.contains($0) } ?? false
        }
        guard active(generation), succeeded || !retained.isEmpty else { return 0 }
        allItems += retained
        librariesTask = nil
        itemsTask = nil
        var seen = Set<String>()
        mediaItems = allItems.filter {
            $0.artPath(for: imageSource, includePostersInMixed: includePostersInMixed) != nil && seen.insert($0.titleKey).inserted
        }
        // Remove cached candidates excluded by the successfully fetched catalogue.
        let available = Set(mediaItems.map(\.titleKey))
        pool.removeAll { !available.contains($0.titleKey) }
        queuedBytes = pool.reduce(0) { $0 + ImageCache.byteCost(of: $1.image) }
        reshuffleIndices()
        return mediaItems.count
    }

    @discardableResult
    func loadMediaItems(libraryIds: [String]) async -> Int {
        await loadMediaItems(selection: libraryIds.isEmpty ? .all : .selected(Set(libraryIds)))
    }

    /// Call with count:1 to reveal the first image promptly, then fill further
    /// slots while the background queue replenishes. The total queue is bounded.
    @discardableResult
    func prefill(count: Int? = nil) async -> Int {
        guard !isStopped, !Task.isCancelled, !isRefilling, !mediaItems.isEmpty else { return pool.count }
        let refillID = UUID()
        activeRefillID = refillID
        defer { if activeRefillID == refillID { activeRefillID = nil } }
        let target = min(poolSize, max(0, count ?? poolSize), mediaItems.count)
        var attempts = 0
        var failures = 0
        let generation = catalogueGeneration
        let request = requestGeneration
        while pool.count < target, attempts < max(target * 2, mediaItems.count), failures < 3,
              active(generation), activeRequest(request) {
            attempts += 1
            guard let next = nextMediaItem() else { break }
            if pool.contains(where: { $0.titleKey == next.item.titleKey }) { continue }
            if let loaded = await loadImage(for: next.item, artPath: next.artPath) {
                guard active(generation), activeRequest(request) else { return isStopped ? 0 : pool.count }
                if !pool.contains(where: { $0.titleKey == loaded.titleKey }), !enqueue(loaded) { break }
                failures = 0
            } else {
                failures += 1
            }
        }
        if activeRequest(request), pool.count > 0, lastRefillResult != "offline cache" { lastRefillResult = "\(pool.count)/\(poolSize)" }
        return isStopped ? 0 : pool.count
    }

    func takeImage() async -> ImageWithMetadata? {
        guard !isStopped, !Task.isCancelled else { return nil }
        while !pool.isEmpty {
            let candidate = pool.removeFirst()
            queuedBytes -= ImageCache.byteCost(of: candidate.image)
            guard let lease = await registry.reserve(artPath: candidate.artPath, titleKey: candidate.titleKey, namespace: namespace) else { continue }
            guard !isStopped, !Task.isCancelled else {
                await registry.release(lease: lease)
                return nil
            }
            leases[lease.id] = lease
            triggerRefillIfNeeded()
            return candidate.reserved(with: lease)
        }
        triggerRefillIfNeeded()
        return nil
    }

    func release(item: ImageWithMetadata) async {
        if let lease = item.lease { await release(lease: lease) }
    }

    func release(lease: ReservationLease) async {
        guard leases.removeValue(forKey: lease.id) != nil else { return }
        await registry.release(lease: lease)
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        catalogueGeneration += 1
        requestGeneration += 1
        refillTask?.cancel()
        refillTask = nil
        refillTaskID = nil
        activeRefillID = nil
        librariesTask?.cancel()
        librariesTask = nil
        itemsTask?.cancel()
        itemsTask = nil
        pool.removeAll()
        queuedBytes = 0
        mediaItems.removeAll()
        shuffledIndices.removeAll()
        freshUntil.removeAll()
        invalidArtworkPaths.removeAll()
        cache.clear()
        let held = Array(leases.values)
        leases.removeAll()
        await ImageRequestCoalescer.shared.cancel(owner: owner)
        for lease in held { await registry.release(lease: lease) }
        lastRefillResult = "stopped"
    }

    func stats() -> PoolStats {
        PoolStats(poolDepth: pool.count, poolCapacity: poolSize,
                  reservedByThisPool: leases.count, lastRefillResult: lastRefillResult,
                  queuedBytes: queuedBytes, queueByteLimit: Self.queueByteLimit)
    }

    private func active(_ generation: Int) -> Bool {
        !isStopped && !Task.isCancelled && catalogueGeneration == generation
    }

    private func triggerRefillIfNeeded() {
        guard !isStopped, !isRefilling, refillTask == nil, pool.count < max(1, poolSize / 2) else { return }
        let taskID = UUID()
        refillTaskID = taskID
        refillTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.prefill()
            await self.refillFinished(taskID)
        }
    }

    private func refillFinished(_ taskID: UUID) {
        guard refillTaskID == taskID else { return }
        refillTask = nil
        refillTaskID = nil
    }

    private func reshuffleIndices() {
        shuffledIndices = Array(mediaItems.indices).shuffled()
        currentIndex = 0
    }

    private func nextMediaItem() -> (item: MediaItem, artPath: String)? {
        guard !mediaItems.isEmpty else { return nil }
        if currentIndex >= shuffledIndices.count { reshuffleIndices() }
        guard let index = shuffledIndices.dropFirst(currentIndex).first else { return nil }
        currentIndex += 1
        let item = mediaItems[index]
        guard let path = item.artPath(for: imageSource, includePostersInMixed: includePostersInMixed) else { return nil }
        return (item, path)
    }

    private func key(_ path: String) -> String { "\(namespace)|\(path)|\(cellWidth)x\(cellHeight)" }

    private func candidate(_ item: MediaItem, artPath: String, image: NSImage) -> ImageWithMetadata {
        ImageWithMetadata(artPath: artPath, image: image, title: item.title, year: item.year,
                          titleKey: item.titleKey, libraryId: item.libraryId)
    }

    private func loadImage(for item: MediaItem, artPath: String) async -> ImageWithMetadata? {
        guard !isStopped, !Task.isCancelled, !invalidArtworkPaths.contains(artPath) else { return nil }
        let request = requestGeneration
        let requestOwner = owner
        let width = cellWidth
        let height = cellHeight
        let cacheKey = key(artPath)
        if let until = freshUntil[cacheKey], until > now(), let image = cache.get(cacheKey) {
            return candidate(item, artPath: artPath, image: image)
        }
        if let diskCache, let image = await diskCache.get(artPath, width: width, height: height, allowStale: false) {
            guard activeRequest(request) else { return nil }
            cache.set(cacheKey, image: image)
            freshUntil[cacheKey] = now().addingTimeInterval(60)
            return candidate(item, artPath: artPath, image: image)
        }
        guard activeRequest(request) else { return nil }
        if networkRetryAfter.map({ $0 > now() }) != true {
            do {
                let image = try await ImageRequestCoalescer.shared.image(for: cacheKey, owner: requestOwner) { [provider] in
                    let fetched = try await provider.fetchImage(path: artPath, width: width, height: height)
                    try Task.checkCancellation()
                    return fetched
                }
                guard activeRequest(request) else { return nil }
                networkRetryAfter = nil
                cache.set(cacheKey, image: image)
                freshUntil[cacheKey] = now().addingTimeInterval(DiskCache.maxAge)
                if let diskCache {
                    let source = item.artPaths.first(where: { $0.value == artPath })?.key ?? imageSource
                    await diskCache.store(artPath, image: image, item: item, source: source, width: width, height: height)
                    guard activeRequest(request) else { return nil }
                }
                return candidate(item, artPath: artPath, image: image)
            } catch {
                guard activeRequest(request) else { return nil }
                lastRefillResult = errorCategory(error)
                switch classify(error) {
                case .missingArtwork, .invalidImageData:
                    invalidArtworkPaths.insert(artPath)
                case .authenticationRequired, .invalidCredential:
                    lastLoadError = .authenticationRequired
                    networkRetryAfter = .distantFuture
                case .throttled(let delay):
                    networkRetryAfter = now().addingTimeInterval(min(300, max(1, delay ?? retryInterval)))
                default: networkRetryAfter = now().addingTimeInterval(retryInterval)
                }
            }
        }
        guard activeRequest(request) else { return nil }
        if let diskCache, let image = await diskCache.get(artPath, width: width, height: height, allowUndersized: true) {
            guard activeRequest(request) else { return nil }
            lastRefillResult = "offline cache"
            return candidate(item, artPath: artPath, image: image)
        }
        return nil
    }

    private func recordLoadError(_ error: Error) {
        // A later unavailable library must not hide the actionable reconnect
        // requirement returned by an earlier library in the same refresh.
        guard lastLoadError != .authenticationRequired, lastLoadError != .invalidCredential else { return }
        lastLoadError = classify(error)
        lastRefillResult = errorCategory(error)
    }

    private func classify(_ error: Error) -> MediaNetworkError {
        if let error = error as? MediaNetworkError { return error }
        return error is URLError ? .unavailable : .invalidResponse
    }

    private func errorCategory(_ error: Error) -> String {
        if let error = error as? MediaNetworkError {
            switch error {
            case .authenticationRequired, .invalidCredential: return "sign in required"
            case .missingArtwork, .invalidImageData: return "artwork unavailable"
            case .throttled: return "server busy"
            case .unavailable: return "offline"
            default: return "request failed"
            }
        }
        if error is CancellationError { return "cancelled" }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return "network: \(nsError.code)" }
        return "request failed"
    }
}
