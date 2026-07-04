//
//  ImageCache.swift
//  PlexSaver
//

import AppKit

/// Thread-safe in-memory image cache backed by `NSCache`. Eviction is handled
/// by AppKit using a size-class heuristic (not strict LRU, but close enough
/// for our modest pool sizes). We wrap NSCache so the rest of the codebase
/// interacts with a narrow, value-typed API.
final class ImageCache {
    private let cache = NSCache<NSString, NSImage>()

    init(maxSize: Int = 100) {
        cache.countLimit = maxSize
    }

    func get(_ key: String) -> NSImage? {
        return cache.object(forKey: key as NSString)
    }

    func set(_ key: String, image: NSImage) {
        cache.setObject(image, forKey: key as NSString)
    }

    func clear() {
        cache.removeAllObjects()
    }
}
