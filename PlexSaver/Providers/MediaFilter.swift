import Foundation

/// Selections are scoped to a connection profile by Preferences. A selection
/// matches any value within a category and every enabled category.
struct MediaFilter: Codable, Equatable, Sendable {
    var genres: [String] = []
    var collections: [String] = []
    var favoritesOnly: Bool = false
    var unwatchedOnly: Bool = false

    var isEmpty: Bool { genres.isEmpty && collections.isEmpty && !favoritesOnly && !unwatchedOnly }

    func matches(_ item: MediaItem) -> Bool {
        guard Self.intersects(genres, item.genres), Self.intersects(collections, item.collections) else { return false }
        if favoritesOnly && item.isFavorite != true { return false }
        if unwatchedOnly && item.isWatched != false { return false }
        return true
    }

    func filtered(_ items: [MediaItem]) -> [MediaItem] { items.filter(matches) }

    /// Stale selections from another provider never produce an invisible filter.
    func supported(by capabilities: MediaFilterCapabilities) -> MediaFilter {
        MediaFilter(genres: capabilities.supportsGenres ? genres : [],
                    collections: capabilities.supportsCollections ? collections : [],
                    favoritesOnly: capabilities.supportsFavorites && favoritesOnly,
                    unwatchedOnly: capabilities.supportsUnwatched && unwatchedOnly)
    }

    private static func intersects(_ selected: [String], _ available: [String]?) -> Bool {
        if selected.isEmpty { return true }
        let values = Set((available ?? []).map(normalized))
        return selected.contains { values.contains(normalized($0)) }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct MediaFilterCapabilities: Equatable, Sendable {
    var supportsGenres: Bool = false
    var supportsCollections: Bool = false
    var supportsFavorites: Bool = false
    var supportsUnwatched: Bool = false
    var hasFilters: Bool { supportsGenres || supportsCollections || supportsFavorites || supportsUnwatched }
}

struct MediaFilterOptions: Equatable, Sendable {
    var genres: [String] = []
    var collections: [String] = []

    init(genres: [String] = [], collections: [String] = []) {
        self.genres = Self.uniqueSorted(genres)
        self.collections = Self.uniqueSorted(collections)
    }

    init(items: [MediaItem]) {
        self.init(genres: items.flatMap { $0.genres ?? [] }, collections: items.flatMap { $0.collections ?? [] })
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
