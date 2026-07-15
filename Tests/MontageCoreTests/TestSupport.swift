import AppKit
@testable import MontageCore

enum MockError: Error { case imageFailed }

/// Minimal in-memory `MediaProvider` for pool tests: deterministic items,
/// no network, and a toggle to simulate image-fetch failures.
actor MockProvider: MediaProvider {
    nonisolated let serverName = "Mock"

    private let libraries: [MediaLibrary]
    private let itemsByLibrary: [String: [MediaItem]]
    private var failImages: Bool

    init(itemsByLibrary: [String: [MediaItem]], failImages: Bool = false) {
        self.itemsByLibrary = itemsByLibrary
        self.libraries = itemsByLibrary.keys.sorted().map { MediaLibrary(id: $0, name: $0, type: "movies") }
        self.failImages = failImages
    }

    func setFailImages(_ value: Bool) { failImages = value }

    func fetchLibraries() async throws -> [MediaLibrary] { libraries }

    func fetchItems(libraryId: String) async throws -> [MediaItem] { itemsByLibrary[libraryId] ?? [] }

    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        if failImages { throw MockError.imageFailed }
        return NSImage(size: NSSize(width: 2, height: 2))
    }
}

/// `count` distinct fanart items with distinct titles (so title-key dedupe is a
/// no-op unless a test intends otherwise).
func makeItems(_ count: Int, artPrefix: String = "/art/") -> [MediaItem] {
    (0..<count).map { i in
        MediaItem(id: "id\(i)", title: "Movie \(i)", year: 2000 + i, artPaths: [.fanart: "\(artPrefix)\(i)"])
    }
}

/// Deterministic RNG (xorshift64*) so the interleaving property test is
/// reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed != 0 ? seed : 0x9e3779b97f4a7c15 }
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545F4914F6CDD1D
    }
}
