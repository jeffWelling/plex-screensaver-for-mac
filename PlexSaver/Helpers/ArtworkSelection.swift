import Foundation

/// Both artwork types remain available, with a predictable framing preference.
enum ArtworkSelection {
    static func path(for item: MediaItem, source: ImageSourceType,
                     includePostersInMixed: Bool = true, width: Int, height: Int) -> String? {
        guard source == .mixed else { return item.artPaths[source] }
        guard includePostersInMixed else { return item.artPaths[.fanart] }
        let preferred: ImageSourceType = width >= height ? .fanart : .posters
        let fallback: ImageSourceType = preferred == .fanart ? .posters : .fanart
        return item.artPaths[preferred] ?? item.artPaths[fallback]
    }
}
