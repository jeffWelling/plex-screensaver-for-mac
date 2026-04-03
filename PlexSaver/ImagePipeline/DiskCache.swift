//
//  DiskCache.swift
//  PlexSaver
//
//  Persistent JPEG image cache. Stores images as files on disk with a JSON
//  manifest tracking entries, total size, and config fingerprint.
//

import AppKit
import CryptoKit
import os.log

actor DiskCache {
    private let cacheDirectory: URL
    private let manifestURL: URL
    private let maxSizeBytes: Int
    private var manifest: CacheManifest
    private var isLoaded = false

    /// Default max cache size: 1 GB
    static let defaultMaxSize = 1_073_741_824

    /// Cache entries older than this are evicted on load (7 days).
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    init(maxSize: Int = DiskCache.defaultMaxSize) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.montage.Montage", isDirectory: true)
        self.cacheDirectory = base.appendingPathComponent("images", isDirectory: true)
        self.manifestURL = base.appendingPathComponent("manifest.json")
        self.maxSizeBytes = maxSize
        self.manifest = CacheManifest(serverURL: "", imageSource: "", lastRefresh: nil, entries: [], totalSize: 0)
    }

    // MARK: - Lifecycle

    /// Load the manifest from disk. Call once before using the cache.
    func load() {
        guard !isLoaded else { return }
        isLoaded = true

        // Ensure directories exist
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let loaded = try? decoder.decode(CacheManifest.self, from: data) else {
            OSLog.info("DiskCache: No existing manifest, starting fresh")
            return
        }

        // Prune entries whose files no longer exist or are older than maxAge
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        var valid: [CacheEntry] = []
        var size: Int64 = 0
        for entry in loaded.entries {
            let file = cacheDirectory.appendingPathComponent(entry.filename)
            if entry.lastAccess < cutoff {
                try? FileManager.default.removeItem(at: file)
            } else if FileManager.default.fileExists(atPath: file.path) {
                valid.append(entry)
                size += entry.size
            }
        }

        manifest = CacheManifest(
            serverURL: loaded.serverURL,
            imageSource: loaded.imageSource,
            lastRefresh: loaded.lastRefresh,
            entries: valid,
            totalSize: size
        )
        OSLog.info("DiskCache: Loaded manifest with \(valid.count) entries (\(size / 1_048_576) MB)")
    }

    // MARK: - Config Validation

    /// Check if the cache matches the current config. Returns true if valid.
    /// If config changed, the cache is cleared.
    func validateConfig(serverURL: String, imageSource: ImageSourceType) -> Bool {
        let source = imageSource.rawValue

        if manifest.serverURL == serverURL && manifest.imageSource == source {
            return true
        }

        if !manifest.entries.isEmpty {
            OSLog.info("DiskCache: Config changed (server or source), clearing cache")
            clearSync()
        }

        manifest.serverURL = serverURL
        manifest.imageSource = source
        saveManifest()
        return false
    }

    /// Whether the cache has been refreshed from the network within `maxAge`.
    var isFresh: Bool {
        guard let lastRefresh = manifest.lastRefresh else { return false }
        return Date().timeIntervalSince(lastRefresh) < Self.maxAge
    }

    /// Mark that a successful network refresh has completed.
    func markRefreshed() {
        manifest.lastRefresh = Date()
        saveManifest()
    }

    // MARK: - Read

    /// Retrieve a cached image by its art path key.
    func get(_ key: String) -> NSImage? {
        guard let entry = manifest.entries.first(where: { $0.key == key }) else {
            return nil
        }

        let file = cacheDirectory.appendingPathComponent(entry.filename)
        guard let image = NSImage(contentsOf: file) else {
            // File unreadable — remove stale entry
            removeEntry(key)
            return nil
        }

        // Touch access time for LRU
        touchEntry(key)
        return image
    }

    /// Load up to `limit` cached images (most recently accessed first).
    func allCachedImages(limit: Int) -> [NSImage] {
        let sorted = manifest.entries.sorted { $0.lastAccess > $1.lastAccess }
        var images: [NSImage] = []

        for entry in sorted.prefix(limit) {
            let file = cacheDirectory.appendingPathComponent(entry.filename)
            if let image = NSImage(contentsOf: file) {
                images.append(image)
            }
        }

        return images
    }

    // MARK: - Write

    /// Store an image in the cache under the given art path key.
    func store(_ key: String, image: NSImage) {
        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return
        }

        let filename = Self.filename(for: key)
        let file = cacheDirectory.appendingPathComponent(filename)

        do {
            try jpegData.write(to: file, options: .atomic)
        } catch {
            OSLog.info("DiskCache: Failed to write \(filename): \(error.localizedDescription)")
            return
        }

        let size = Int64(jpegData.count)

        // Remove old entry for this key if it exists
        if let idx = manifest.entries.firstIndex(where: { $0.key == key }) {
            manifest.totalSize -= manifest.entries[idx].size
            manifest.entries.remove(at: idx)
        }

        manifest.entries.append(CacheEntry(
            key: key,
            filename: filename,
            size: size,
            lastAccess: Date()
        ))
        manifest.totalSize += size

        evictIfNeeded()
        saveManifest()
    }

    // MARK: - Info

    var count: Int {
        manifest.entries.count
    }

    // MARK: - Clear

    func clear() {
        clearSync()
        saveManifest()
    }

    // MARK: - Private

    private func clearSync() {
        for entry in manifest.entries {
            let file = cacheDirectory.appendingPathComponent(entry.filename)
            try? FileManager.default.removeItem(at: file)
        }
        manifest.entries.removeAll()
        manifest.totalSize = 0
    }

    private func touchEntry(_ key: String) {
        if let idx = manifest.entries.firstIndex(where: { $0.key == key }) {
            manifest.entries[idx].lastAccess = Date()
        }
    }

    private func removeEntry(_ key: String) {
        if let idx = manifest.entries.firstIndex(where: { $0.key == key }) {
            let entry = manifest.entries[idx]
            let file = cacheDirectory.appendingPathComponent(entry.filename)
            try? FileManager.default.removeItem(at: file)
            manifest.totalSize -= entry.size
            manifest.entries.remove(at: idx)
            saveManifest()
        }
    }

    /// Evict LRU entries until total size is under 90% of max.
    private func evictIfNeeded() {
        let target = Int64(Double(maxSizeBytes) * 0.9)
        guard manifest.totalSize > Int64(maxSizeBytes) else { return }

        // Sort by last access, oldest first
        manifest.entries.sort { $0.lastAccess < $1.lastAccess }

        while manifest.totalSize > target, let oldest = manifest.entries.first {
            let file = cacheDirectory.appendingPathComponent(oldest.filename)
            try? FileManager.default.removeItem(at: file)
            manifest.totalSize -= oldest.size
            manifest.entries.removeFirst()
            OSLog.info("DiskCache: Evicted \(oldest.filename)")
        }
    }

    private func saveManifest() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// Generate a deterministic filename from an art path key.
    static func filename(for key: String) -> String {
        let hash = SHA256.hash(data: Data(key.utf8))
        let prefix = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(prefix).jpg"
    }
}

// MARK: - Models

private struct CacheManifest: Codable {
    var serverURL: String
    var imageSource: String
    var lastRefresh: Date?
    var entries: [CacheEntry]
    var totalSize: Int64
}

private struct CacheEntry: Codable {
    let key: String
    let filename: String
    let size: Int64
    var lastAccess: Date
}
