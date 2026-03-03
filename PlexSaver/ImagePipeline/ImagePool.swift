//
//  ImagePool.swift
//  PlexSaver
//

import AppKit
import os.log

actor ImagePool {
    private let client: PlexClient
    private let imageSource: ImageSourceType
    private let cellWidth: Int
    private let cellHeight: Int
    private let cache: ImageCache

    private var mediaItems: [PlexMediaItem] = []
    private var shuffledIndices: [Int] = []
    private var currentIndex = 0
    private var pool: [NSImage] = []
    private let poolSize: Int
    private var isRefilling = false
    private var isStopped = false

    init(client: PlexClient, imageSource: ImageSourceType, cellWidth: Int, cellHeight: Int, poolSize: Int) {
        self.client = client
        self.imageSource = imageSource
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.poolSize = poolSize
        self.cache = ImageCache(maxSize: poolSize * 2)
    }

    /// Load media items from configured libraries. Returns count of items with art.
    @discardableResult
    func loadMediaItems(libraryIds: [String]) async -> Int {
        var allItems: [PlexMediaItem] = []
        do {
            if libraryIds.isEmpty {
                // Fetch all libraries
                let libraries = try await client.fetchLibraries()
                for library in libraries {
                    let items = try await client.fetchAllItems(sectionId: library.key)
                    allItems.append(contentsOf: items)
                }
            } else {
                for id in libraryIds {
                    let items = try await client.fetchAllItems(sectionId: id)
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
            if let image = await fetchNextImage() {
                pool.append(image)
            }
        }

        OSLog.info("ImagePool: Pool pre-filled with \(pool.count) images")
        return pool.count
    }

    /// Take an image from the pool. Returns nil if pool is empty.
    func takeImage() -> NSImage? {
        guard !pool.isEmpty else { return nil }
        let image = pool.removeFirst()

        // Trigger background refill if pool is getting low
        if pool.count < poolSize / 2 && !isRefilling {
            Task { await refillPool() }
        }

        return image
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

    private func nextMediaItem() -> PlexMediaItem? {
        guard !mediaItems.isEmpty else { return nil }

        if currentIndex >= shuffledIndices.count {
            reshuffleIndices()
        }

        let item = mediaItems[shuffledIndices[currentIndex]]
        currentIndex += 1
        return item
    }

    private func fetchNextImage() async -> NSImage? {
        guard let item = nextMediaItem(),
              let artPath = item.artPath(for: imageSource) else {
            return nil
        }

        // Check cache first
        if let cached = cache.get(artPath) {
            return cached
        }

        do {
            let image = try await client.fetchImage(imagePath: artPath, width: cellWidth, height: cellHeight)
            cache.set(artPath, image: image)
            return image
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
            if let image = await fetchNextImage() {
                pool.append(image)
            } else {
                // Skip failed fetches but don't retry endlessly
                break
            }
        }
    }
}
