// Persistent, connection-scoped artwork cache. Every transaction reloads the
// manifest under a file lock, so preview and screensaver processes cannot lose
// one another's updates. Old account-unscoped caches are deliberately not read.

import AppKit
import CryptoKit
import ImageIO
import Darwin
import os.log

struct DiskCacheSummary: Sendable {
    let count: Int
    let sizeBytes: Int64
    let lastRefresh: Date?
    let lastPreparedDate: Date?
}

struct CachedArtworkDescriptor: Sendable {
    let artPath: String
    let item: MediaItem
    let source: ImageSourceType
    let width: Int
    let height: Int
    let downloadedAt: Date
}

struct CachedArtwork {
    let artPath: String
    let image: NSImage
    let item: MediaItem
    let source: ImageSourceType
    let width: Int
    let height: Int
    let downloadedAt: Date
}

actor DiskCacheCoordinator {
    static let shared = DiskCacheCoordinator()
    private var caches: [String: DiskCache] = [:]

    func cache(for namespace: String) -> DiskCache {
        if let cache = caches[namespace] { return cache }
        let cache = DiskCache(namespace: namespace)
        caches[namespace] = cache
        return cache
    }
}

actor DiskCache {
    static let defaultMaxSize = 512 * 1_048_576
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private let namespace: String
    private let directory: URL
    private let maxSizeBytes: Int64
    private let now: @Sendable () -> Date
    private var manifest: CacheManifest
    private static let processLock = NSLock()

    init(namespace: String = "default", maxSize: Int = DiskCache.defaultMaxSize,
         directory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.namespace = namespace
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppConstants.module, isDirectory: true)
            .appendingPathComponent("artwork-v2", isDirectory: true)
        self.directory = base.appendingPathComponent(Self.digest(namespace), isDirectory: true)
        self.maxSizeBytes = Int64(max(0, maxSize))
        self.now = now
        self.manifest = CacheManifest(namespace: namespace)
    }

    func load() { _ = transaction { () } }

    static func normalizeServerURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? trimmed
    }

    var isFresh: Bool {
        transaction { manifest.lastRefresh.map { now().timeIntervalSince($0) < Self.maxAge } ?? false } ?? false
    }

    var count: Int { transaction { manifest.entries.count } ?? 0 }

    func summary() -> DiskCacheSummary {
        transaction {
            DiskCacheSummary(count: manifest.entries.count,
                             sizeBytes: manifest.entries.reduce(0) { $0 + $1.size },
                             lastRefresh: manifest.lastRefresh, lastPreparedDate: manifest.lastPreparedDate)
        } ?? DiskCacheSummary(count: 0, sizeBytes: 0, lastRefresh: nil, lastPreparedDate: nil)
    }

    /// Only sufficiently large variants satisfy an online request. Stale
    /// records remain available for offline fallback, without becoming fresh
    /// just because they have been displayed.
    func get(_ key: String, width: Int = 0, height: Int = 0, allowStale: Bool = true,
             allowUndersized: Bool = false) -> NSImage? {
        transaction {
            var invalid = Set<String>()
            defer { removeInvalidFiles(invalid) }
            let candidates = manifest.entries.indices.filter {
                let entry = manifest.entries[$0]
                return entry.artPath == key && (allowUndersized || (entry.width >= width && entry.height >= height))
                    && (allowStale || now().timeIntervalSince(entry.downloadedAt) < Self.maxAge)
            }.sorted {
                let areaA = manifest.entries[$0].width * manifest.entries[$0].height
                let areaB = manifest.entries[$1].width * manifest.entries[$1].height
                return allowUndersized ? areaA > areaB : areaA < areaB
            }
            for index in candidates {
                let entry = manifest.entries[index]
                if let image = PreparedArtwork.read(directory.appendingPathComponent(entry.filename),
                                                    width: width, height: height) {
                    manifest.entries[index].lastAccess = now()
                    return image
                }
                if !Task.isCancelled { invalid.insert(entry.filename) }
            }
            return nil
        } ?? nil
    }

    func cachedImages(limit: Int, selection: LibrarySelection,
                      imageSource: ImageSourceType, includePostersInMixed: Bool = true,
                      width: Int, height: Int,
                      decodedByteLimit: Int = ImagePool.queueByteLimit,
                      filter: MediaFilter = MediaFilter(), recentTitleDates: [String: Date] = [:]) -> [CachedArtwork] {
        transaction {
            let candidates = manifest.entries.filter { entry in
                guard selection.includes(entry.item.libraryId), filter.matches(entry.item) else { return false }
                return entry.item.mediaType == "photo" || imageSource == entry.source ||
                    (imageSource == .mixed && (includePostersInMixed || entry.source == .fanart))
            }.sorted {
                let seenA = recentTitleDates[RecentTitleHistory.digest($0.item.titleKey)]
                let seenB = recentTitleDates[RecentTitleHistory.digest($1.item.titleKey)]
                if seenA != seenB { return (seenA ?? .distantPast) < (seenB ?? .distantPast) }
                let adequateA = $0.width >= width && $0.height >= height
                let adequateB = $1.width >= width && $1.height >= height
                if adequateA != adequateB { return adequateA }
                if imageSource == .mixed, $0.source != $1.source {
                    let preferred: ImageSourceType = width >= height ? .fanart : .posters
                    if $0.source == preferred { return true }
                    if $1.source == preferred { return false }
                }
                return $0.lastAccess > $1.lastAccess
            }
            var seenTitles = Set<String>()
            var results: [CachedArtwork] = []
            var decodedBytes = 0
            let byteLimit = max(0, decodedByteLimit)
            for entry in candidates {
                guard !Task.isCancelled, results.count < max(0, limit), decodedBytes < byteLimit else { break }
                guard !seenTitles.contains(entry.item.titleKey),
                      let image = PreparedArtwork.read(directory.appendingPathComponent(entry.filename),
                                                       width: width, height: height) else { continue }
                let cost = ImageCache.byteCost(of: image)
                // Stop before retaining another bitmap beyond the caller's
                // queue budget; a count limit alone can decode many large files.
                guard cost > 0, cost <= byteLimit - decodedBytes else { break }
                decodedBytes += cost
                seenTitles.insert(entry.item.titleKey)
                results.append(CachedArtwork(artPath: entry.artPath, image: image, item: entry.item,
                                             source: logicalSource(entry, requested: imageSource, width: width, height: height), width: entry.width, height: entry.height,
                                             downloadedAt: entry.downloadedAt))
            }
            return results
        } ?? []
    }

    /// Read image headers without retaining decoded bitmaps. Count titles, not
    /// size variants, and keep stale artwork available for offline readiness.
    /// Requested dimensions identify prepared variants; the original source or
    /// decoder's pixel limit can legitimately have fewer actual pixels.
    func availableArtwork(selection: LibrarySelection, imageSource: ImageSourceType,
                          filter: MediaFilter = MediaFilter(), width: Int, height: Int,
                          requireAdequateSize: Bool = true, uniqueTitles: Bool = true) -> [CachedArtworkDescriptor] {
        transaction {
            var seenTitles = Set<String>()
            var result: [CachedArtworkDescriptor] = []
            let candidates = manifest.entries.sorted {
                if imageSource == .mixed, $0.source != $1.source {
                    let preferred: ImageSourceType = width >= height ? .fanart : .posters
                    if $0.source == preferred { return true }
                    if $1.source == preferred { return false }
                }
                return $0.downloadedAt > $1.downloadedAt
            }
            for entry in candidates {
                guard !Task.isCancelled else { break }
                guard selection.includes(entry.item.libraryId), filter.matches(entry.item),
                      imageSource == .mixed || imageSource == entry.source || entry.item.mediaType == "photo",
                      !uniqueTitles || !seenTitles.contains(entry.item.titleKey),
                      !requireAdequateSize || (entry.width >= width && entry.height >= height),
                      imageDimensions(directory.appendingPathComponent(entry.filename)) != nil else { continue }
                seenTitles.insert(entry.item.titleKey)
                result.append(CachedArtworkDescriptor(artPath: entry.artPath, item: entry.item,
                    source: logicalSource(entry, requested: imageSource, width: width, height: height),
                    width: entry.width, height: entry.height, downloadedAt: entry.downloadedAt))
            }
            return result
        } ?? []
    }

    /// Update metadata after a successful catalog fetch without deleting the
    /// artwork that still makes an unavailable server usable offline.
    func refreshMetadata(_ items: [MediaItem], libraryIDs: [String]) {
        guard !Task.isCancelled else { return }
        _ = transaction {
            guard !Task.isCancelled else { return }
            let libraries = Set(libraryIDs)
            var catalog: [String: MediaItem] = [:]
            for item in items {
                guard let library = item.libraryId, libraries.contains(library) else { continue }
                catalog["\(library)|\(item.id)"] = item
            }
            for index in manifest.entries.indices {
                let entry = manifest.entries[index]
                guard let library = entry.item.libraryId, libraries.contains(library),
                      let item = catalog["\(library)|\(entry.item.id)"] else { continue }
                manifest.entries[index].item = item
            }
        }
    }

    func markPreparationCompleted(_ date: Date? = nil) {
        guard !Task.isCancelled else { return }
        _ = transaction {
            guard !Task.isCancelled else { return }
            manifest.lastPreparedDate = date ?? now()
        }
    }

    private func logicalSource(_ entry: CacheEntry, requested: ImageSourceType, width: Int, height: Int) -> ImageSourceType {
        guard entry.item.mediaType == "photo" else { return entry.source }
        return requested == .mixed ? (width >= height ? .fanart : .posters) : requested
    }

    private func imageDimensions(_ url: URL) -> (width: Int, height: Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= URLSessionTransport.maximumImageBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0 else { return nil }
        return (width.intValue, height.intValue)
    }

    /// JPEG encoding uses the already prepared CGImage directly, avoiding a
    /// TIFF roundtrip and an additional full-size bitmap decode.
    func store(_ key: String, image: NSImage, item: MediaItem, source: ImageSourceType,
               width: Int, height: Int) {
        guard !Task.isCancelled, let jpeg = PreparedArtwork.jpegData(image) else { return }
        _ = transaction {
            guard !Task.isCancelled else { return }
            let variant = "\(key)|\(width)x\(height)"
            let filename = Self.filename(for: variant)
            do {
                try jpeg.write(to: directory.appendingPathComponent(filename), options: .atomic)
            } catch {
                OSLog.info("Artwork cache write failed")
                return
            }
            manifest.entries.removeAll { $0.filename == filename }
            manifest.entries.append(CacheEntry(artPath: key, filename: filename,
                                               size: Int64(jpeg.count), width: width, height: height,
                                               source: source, item: item,
                                               downloadedAt: now(), lastAccess: now()))
            manifest.lastRefresh = now()
            evictIfNeeded()
        }
    }

    func clear() {
        _ = transaction {
            for entry in manifest.entries { try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.filename)) }
            manifest = CacheManifest(namespace: namespace)
        }
    }

    private func transaction<T>(_ body: () -> T) -> T? {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        let lockURL = directory.appendingPathComponent("manifest.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else { return nil }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        reloadAndReconcile()
        let result = body()
        saveManifest()
        return result
    }

    private func reloadAndReconcile() {
        let url = directory.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let loaded = try? decoder.decode(CacheManifest.self, from: data),
           loaded.namespace == namespace, loaded.version == 2 {
            manifest = loaded
        } else {
            manifest = CacheManifest(namespace: namespace)
        }
        manifest.entries = manifest.entries.filter { entry in
            // A malformed manifest must not escape this connection directory.
            guard entry.filename == Self.filename(for: "\(entry.artPath)|\(entry.width)x\(entry.height)"),
                  (1...8192).contains(entry.width), (1...8192).contains(entry.height), entry.size >= 0 else { return false }
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.filename).path)
        }
        for index in manifest.entries.indices {
            let file = directory.appendingPathComponent(manifest.entries[index].filename)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               let size = attributes[.size] as? NSNumber { manifest.entries[index].size = size.int64Value }
        }
        let known = Set(manifest.entries.map(\.filename))
        // Missing/corrupt manifests never leave orphan artwork consuming space.
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "jpg" && !known.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        evictIfNeeded()
    }

    private func removeInvalidFiles(_ filenames: Set<String>) {
        for filename in filenames { try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename)) }
        manifest.entries.removeAll { filenames.contains($0.filename) }
    }

    private func evictIfNeeded() {
        var bytes = manifest.entries.reduce(0) { $0 + $1.size }
        guard bytes > maxSizeBytes else { return }
        let target = maxSizeBytes * 9 / 10
        manifest.entries.sort { $0.lastAccess < $1.lastAccess }
        while bytes > target, !manifest.entries.isEmpty {
            let entry = manifest.entries.removeFirst()
            bytes -= entry.size
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.filename))
        }
    }

    private func saveManifest() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    static func filename(for key: String) -> String { "\(digest(key)).jpg" }
    private static func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CacheManifest: Codable {
    var version = 2
    var namespace: String
    var lastRefresh: Date?
    var lastPreparedDate: Date?
    var entries: [CacheEntry] = []
}

private struct CacheEntry: Codable {
    let artPath: String
    let filename: String
    var size: Int64
    let width: Int
    let height: Int
    let source: ImageSourceType
    var item: MediaItem
    let downloadedAt: Date
    var lastAccess: Date
}

private extension LibrarySelection {
    func includes(_ libraryID: String?) -> Bool {
        switch self {
        case .all: return true
        case .selected(let ids): return libraryID.map { ids.contains($0) } ?? false
        }
    }
}
