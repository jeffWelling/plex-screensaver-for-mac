//
//  ImagePool.swift
//  PlexSaver
//

import AppKit
import os.log

struct ImageWithMetadata {
    let image: NSImage
    let title: String
    let year: Int?
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

        // Filter to items that have art for our source type
        mediaItems = allItems.filter { $0.artPath(for: imageSource) != nil }
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
        guard !pool.isEmpty else { return nil }
        let item = pool.removeFirst()

        // Trigger background refill if pool is getting low
        if pool.count < poolSize / 2 && !isRefilling {
            Task { await refillPool() }
        }

        return item
    }

    /// Stop all background activity.
    func stop() {
        isStopped = true
        pool.removeAll()
        cache.clear()
    }

    // MARK: - Private

    private func reshuffleIndices() {
        shuffledIndices = Array(0..<mediaItems.count).shuffled()
        currentIndex = 0
    }

    private func nextMediaItem() -> MediaItem? {
        guard !mediaItems.isEmpty else { return nil }

        if currentIndex >= shuffledIndices.count {
            reshuffleIndices()
        }

        let item = mediaItems[shuffledIndices[currentIndex]]
        currentIndex += 1
        return item
    }

    private func fetchNextImage() async -> ImageWithMetadata? {
        guard let item = nextMediaItem(),
              let artPath = item.artPath(for: imageSource) else {
            return nil
        }

        // 1. Check in-memory cache
        if let cached = cache.get(artPath) {
            return ImageWithMetadata(image: cached, title: item.title, year: item.year)
        }

        // 2. Check disk cache
        if let disk = diskCache, let cached = await disk.get(artPath) {
            cache.set(artPath, image: cached)
            return ImageWithMetadata(image: cached, title: item.title, year: item.year)
        }

        // 3. Fetch from network, write-through to both caches
        do {
            let image = try await provider.fetchImage(path: artPath, width: cellWidth, height: cellHeight)
            cache.set(artPath, image: image)
            if let disk = diskCache {
                await disk.store(artPath, image: image)
            }
            return ImageWithMetadata(image: image, title: item.title, year: item.year)
        } catch {
            OSLog.info("ImagePool: Failed to fetch image for \(item.title): \(error.localizedDescription)")
            return nil
        }
    }

    private func refillPool() async {
        guard !isRefilling else { return }
        isRefilling = true
        defer { isRefilling = false }

        while pool.count < poolSize && !isStopped {
            if let item = await fetchNextImage() {
                pool.append(item)
            } else {
                // Skip failed fetches but don't retry endlessly
                break
            }
        }
    }
}
