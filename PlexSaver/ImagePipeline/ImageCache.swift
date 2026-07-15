//
//  ImageCache.swift
//  PlexSaver
//

import AppKit

/// Thread-safe in-memory image cache backed by `NSCache`. Eviction is bounded by
/// both a count limit and a byte-cost limit (`totalCostLimit`), so a handful of
/// large 4K fanart images can't blow the memory budget the way a count-only
/// limit allowed (N2). We wrap NSCache so the rest of the codebase interacts
/// with a narrow, value-typed API.
final class ImageCache {
    private let cache = NSCache<NSString, NSImage>()

    /// - Parameters:
    ///   - countLimit: maximum number of images to retain.
    ///   - totalCostLimit: maximum total decoded bytes to retain (0 = unbounded).
    init(countLimit: Int = 100, totalCostLimit: Int = 0) {
        cache.countLimit = countLimit
        if totalCostLimit > 0 {
            cache.totalCostLimit = totalCostLimit
        }
    }

    func get(_ key: String) -> NSImage? {
        return cache.object(forKey: key as NSString)
    }

    func set(_ key: String, image: NSImage) {
        cache.setObject(image, forKey: key as NSString, cost: Self.byteCost(of: image))
    }

    func clear() {
        cache.removeAllObjects()
    }

    /// Approximate decoded byte cost of an image: largest representation's pixel
    /// count × 4 bytes (RGBA). Falls back to the point size when no bitmap rep
    /// exposes pixel dimensions.
    static func byteCost(of image: NSImage) -> Int {
        var pixels = 0
        for rep in image.representations {
            pixels = max(pixels, rep.pixelsWide * rep.pixelsHigh)
        }
        if pixels == 0 {
            pixels = max(0, Int(image.size.width * image.size.height))
        }
        return pixels * 4
    }
}
