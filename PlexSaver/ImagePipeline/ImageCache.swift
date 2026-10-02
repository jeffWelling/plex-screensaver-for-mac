import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A strict process-wide decoded-image budget. NSCache's limits are advisory;
/// explicit LRU eviction bounds retained cache memory across every monitor.
/// Visible layers are a separate unavoidable working set; pool queues are kept
/// small according to their requested pixel dimensions.
final class ImageCache: @unchecked Sendable {
    private struct Entry {
        let image: NSImage
        let cost: Int
        var touched: UInt64
        var owners: Set<UUID>
    }
    private static let lock = NSLock()
    // NSLock guards every read and mutation of these process-wide values.
    // The unsafe annotation describes this existing synchronization boundary;
    // it does not disable concurrency checking for the rest of the cache.
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    nonisolated(unsafe) private static var totalBytes = 0
    nonisolated(unsafe) private static var sequence: UInt64 = 0
    static let processLimitBytes = 96 * 1_048_576
    private let owner = UUID()
    private let countLimit: Int
    private let totalCostLimit: Int

    init(countLimit: Int = 24, totalCostLimit: Int = 32 * 1_048_576) {
        self.countLimit = max(1, countLimit)
        self.totalCostLimit = min(Self.processLimitBytes, max(1, totalCostLimit))
    }

    func get(_ key: String) -> NSImage? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard var entry = Self.entries[key] else { return nil }
        Self.sequence &+= 1
        entry.touched = Self.sequence
        entry.owners.insert(owner)
        Self.entries[key] = entry
        return entry.image
    }

    func set(_ key: String, image: NSImage) {
        let cost = Self.byteCost(of: image)
        guard cost <= totalCostLimit else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var owners = Self.entries[key]?.owners ?? []
        owners.insert(owner)
        if let previous = Self.entries[key] { Self.totalBytes -= previous.cost }
        Self.sequence &+= 1
        Self.entries[key] = Entry(image: image, cost: cost, touched: Self.sequence, owners: owners)
        Self.totalBytes += cost
        let owned = Self.entries.filter { $0.value.owners.contains(owner) }
            .sorted { $0.value.touched < $1.value.touched }
        var ownerCount = owned.count
        var ownerCost = owned.reduce(0) { $0 + $1.value.cost }
        for (key, entry) in owned where ownerCount > countLimit || ownerCost > totalCostLimit {
            if var current = Self.entries[key] {
                current.owners.remove(owner)
                if current.owners.isEmpty {
                    Self.entries.removeValue(forKey: key)
                    Self.totalBytes -= current.cost
                } else { Self.entries[key] = current }
            }
            ownerCount -= 1
            ownerCost -= entry.cost
        }
        while Self.totalBytes > Self.processLimitBytes,
              let oldest = Self.entries.min(by: { $0.value.touched < $1.value.touched }) {
            Self.entries.removeValue(forKey: oldest.key)
            Self.totalBytes -= oldest.value.cost
        }
    }

    func clear() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        for key in Array(Self.entries.keys) {
            guard var entry = Self.entries[key], entry.owners.remove(owner) != nil else { continue }
            if entry.owners.isEmpty {
                Self.entries.removeValue(forKey: key)
                Self.totalBytes -= entry.cost
            } else { Self.entries[key] = entry }
        }
    }

    static var retainedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }

    static func byteCost(of image: NSImage) -> Int {
        let width = image.size.width
        let height = image.size.height
        guard width.isFinite, height.isFinite, width >= 0, height >= 0,
              width <= 32768, height <= 32768 else { return Int.max }
        var cost = 0
        for representation in image.representations {
            if let bitmap = representation as? NSBitmapImageRep {
                cost = max(cost, checkedProduct(bitmap.bytesPerRow, bitmap.pixelsHigh))
            }
        }
        // NSCGImageSnapshotRep reports screen-scaled pixel dimensions even
        // when its original CGImage has fewer pixels. Measure the actual bitmap
        // stride rather than using that representation's virtual dimensions.
        if let bitmap = PreparedArtwork.bitmap(image) {
            cost = max(cost, checkedProduct(bitmap.bytesPerRow, bitmap.height))
        }
        if cost > 0 { return cost }
        return checkedProduct(checkedProduct(Int(width), Int(height)), 4)
    }

    private static func checkedProduct(_ first: Int, _ second: Int) -> Int {
        guard first >= 0, second >= 0 else { return Int.max }
        let product = first.multipliedReportingOverflow(by: second)
        return product.overflow ? Int.max : product.partialValue
    }
}

/// Produces a decoded bitmap on the image-loading actor before assigning it to
/// a layer on the main actor. Disk reads downsample through ImageIO and network
/// NSImages are flattened without converting through TIFF.
enum PreparedArtwork {
    /// Keep one explicit bitmap representation. NSImage(cgImage:size:) creates
    /// a lazy snapshot representation whose dimensions vary with screen scale.
    static func image(_ bitmap: CGImage) -> NSImage {
        let representation = NSBitmapImageRep(cgImage: bitmap)
        let size = NSSize(width: bitmap.width, height: bitmap.height)
        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    /// Return prepared pixels without asking AppKit to render them again at
    /// the host screen's scale. Most artwork already has a bitmap representation.
    static func bitmap(_ image: NSImage) -> CGImage? {
        let representations = image.representations.compactMap { $0 as? NSBitmapImageRep }
            .filter { (1...32768).contains($0.pixelsWide) && (1...32768).contains($0.pixelsHigh) }
        if let representation = representations.max(by: {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }), let bitmap = representation.cgImage {
            return bitmap
        }
        let size = image.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 32768, size.height <= 32768 else { return nil }
        var rectangle = CGRect(origin: .zero, size: size)
        // AppKit documents an identity CTM for a proposed rectangle expressed
        // in pixels. Without it a nil context inherits the screen's 2x scale.
        return image.cgImage(forProposedRect: &rectangle, context: nil,
                             hints: [.ctm: NSAffineTransform()])
    }

    static func read(_ url: URL, width: Int, height: Int) -> NSImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= URLSessionTransport.maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        // The shared decoder preserves aspect-fill resolution, bounds decoded
        // pixels, and prepares the bitmap immediately for both network and disk.
        return try? ArtworkDecoder.decode(data,
                                          width: width > 0 ? width : min(8192, sourceWidth.intValue),
                                          height: height > 0 ? height : min(8192, sourceHeight.intValue))
    }

    static func jpegData(_ image: NSImage) -> Data? {
        guard let bitmap = bitmap(image) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, bitmap,
                                  [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
