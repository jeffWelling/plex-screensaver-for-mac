//
//  ImageCache.swift
//  PlexSaver
//

import AppKit

final class ImageCache {
    private var cache: [String: NSImage] = [:]
    private var accessOrder: [String] = []
    private let maxSize: Int
    private let lock = NSLock()

    init(maxSize: Int = 100) {
        self.maxSize = maxSize
    }

    func get(_ key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }

        guard let image = cache[key] else { return nil }
        // Move to end of access order (most recently used)
        if let idx = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: idx)
            accessOrder.append(key)
        }
        return image
    }

    func set(_ key: String, image: NSImage) {
        lock.lock()
        defer { lock.unlock() }

        if cache[key] != nil {
            // Already cached, just update access order
            if let idx = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: idx)
            }
        } else {
            // Evict LRU if at capacity
            while cache.count >= maxSize, let lruKey = accessOrder.first {
                cache.removeValue(forKey: lruKey)
                accessOrder.removeFirst()
            }
        }

        cache[key] = image
        accessOrder.append(key)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        accessOrder.removeAll()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }
}
