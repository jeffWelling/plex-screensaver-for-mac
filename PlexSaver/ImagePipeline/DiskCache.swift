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
    /// Counts LRU touches since the manifest was last persisted, so access-time
    /// updates are flushed periodically rather than on every read.
    private var touchesSinceSave = 0
    private static let touchSaveThreshold = 16

    /// Default max cache size: 1 GB
    static let defaultMaxSize = 1_073_741_824

    /// Cache entries older than this are evicted on load (7 days).
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    init(maxSize: Int = DiskCache.defaultMaxSize) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppConstants.module, isDirectory: true)
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
        let normalizedURL = Self.normalizeServerURL(serverURL)
        let source = imageSource.rawValue

        if manifest.serverURL == normalizedURL && manifest.imageSource == source {
            return true
        }

        if !manifest.entries.isEmpty {
            OSLog.info("DiskCache: Config changed (server or source), clearing cache")
            clearSync()
        }

        manifest.serverURL = normalizedURL
        manifest.imageSource = source
        // The cache no longer reflects a network refresh for this config, so
        // clear the freshness timestamp — otherwise `isFresh` could report true
        // against an emptied cache and suppress the "Connecting…" banner.
        manifest.lastRefresh = nil
        saveManifest()
        return false
    }

    /// Normalize server URL so cosmetic differences (trailing slash, case in
    /// the scheme/host) don't look like a config change and invalidate the cache.
    /// Internal (not private) so it is unit-testable (A1).
    static func normalizeServerURL(_ url: String) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed = String(trimmed.dropLast())
        }
        return trimmed.lowercased()
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

    /// Load up to `limit` cached images (most recently accessed first), each
    /// paired with its art-path key so the caller can route Phase-1 selection
    /// through `ReservationRegistry` (see U1) and dedupe across monitors.
    ///
    /// When `libraryIds` is non-empty, only images recorded as belonging to one
    /// of those libraries are returned (N3). Entries with no recorded library id
    /// (legacy manifests written before N3) are always included, since their
    /// origin is unknown and excluding them would blank the cached phase.
    func allCachedImages(limit: Int, libraryIds: [String] = []) -> [(key: String, image: NSImage)] {
        let selected = Set(libraryIds)
        let sorted = manifest.entries
            .filter { entry in
                selected.isEmpty || entry.libraryId == nil || selected.contains(entry.libraryId!)
            }
            .sorted { $0.lastAccess > $1.lastAccess }
        var results: [(key: String, image: NSImage)] = []

        for entry in sorted.prefix(limit) {
            let file = cacheDirectory.appendingPathComponent(entry.filename)
            if let image = NSImage(contentsOf: file) {
                results.append((key: entry.key, image: image))
            }
        }

        return results
    }

    // MARK: - Write

    /// Store an image in the cache under the given art path key, optionally
    /// recording the library it came from (N3).
    func store(_ key: String, image: NSImage, libraryId: String? = nil) {
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

        // Remove old entry for this key if it exists. Preserve a previously
        // recorded library id if this store didn't supply one.
        var resolvedLibraryId = libraryId
        if let idx = manifest.entries.firstIndex(where: { $0.key == key }) {
            if resolvedLibraryId == nil { resolvedLibraryId = manifest.entries[idx].libraryId }
            manifest.totalSize -= manifest.entries[idx].size
            manifest.entries.remove(at: idx)
        }

        manifest.entries.append(CacheEntry(
            key: key,
            filename: filename,
            size: size,
            lastAccess: Date(),
            libraryId: resolvedLibraryId
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
            // Persist access times periodically. Screensaver processes are
            // frequently killed rather than cleanly torn down, so unpersisted
            // LRU timestamps would otherwise be lost across restarts and skew
            // eviction/age decisions.
            touchesSinceSave += 1
            if touchesSinceSave >= Self.touchSaveThreshold {
                touchesSinceSave = 0
                saveManifest()
            }
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
    /// Originating library id (N3). Optional so manifests written before this
    /// field existed still decode (absent key → nil).
    var libraryId: String? = nil
}
