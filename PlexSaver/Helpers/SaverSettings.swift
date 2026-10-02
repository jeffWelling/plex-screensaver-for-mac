import Foundation
import CryptoKit

/// An empty explicit selection means no libraries; it never means every library.
enum LibrarySelection: Codable, Equatable, Sendable {
    case all
    case selected(Set<String>)

    func includes(_ id: String) -> Bool {
        switch self {
        case .all: return true
        case .selected(let ids): return ids.contains(id)
        }
    }
}

struct ConnectionProfile: Codable, Equatable, Hashable, Sendable {
    let provider: ProviderType
    let serverURL: String
    let accountID: String
    let serverID: String

    init(provider: ProviderType, serverURL: String, accountID: String, serverID: String = "") {
        self.provider = provider
        self.serverURL = (try? ServerEndpoint(serverURL).canonicalURLString) ?? serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountID = accountID
        self.serverID = serverID
    }

    // Library choices and cache ownership follow the physical server/account,
    // even when discovery chooses a different advertised endpoint.
    static func == (lhs: ConnectionProfile, rhs: ConnectionProfile) -> Bool { lhs.namespace == rhs.namespace }
    func hash(into hasher: inout Hasher) { hasher.combine(namespace) }

    var cacheNamespace: String { namespace }
    var namespace: String {
        let identity = "\(provider.rawValue)|\(serverID.isEmpty ? serverURL : serverID)|\(accountID)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum ArtworkFraming: String, Codable, CaseIterable, Sendable {
    case fill, fit
    var displayName: String { self == .fill ? "Fill frame" : "Show full artwork" }
}

enum PresentationPreset: String, CaseIterable, Sendable {
    case mosaic, posterWall, calm
    var displayName: String {
        switch self { case .mosaic: return "Mosaic"; case .posterWall: return "Poster Wall"; case .calm: return "Calm" }
    }
}

/// Validated once at startup, then passed through the entire run unchanged.
struct SaverSettings: Equatable, Sendable {
    let rows: Int
    let columns: Int
    let autoColumns: Bool
    let rotationInterval: Double
    let imageSource: ImageSourceType
    let showTitleReveal: Bool
    let titleDisplayDuration: Double
    let librarySelection: LibrarySelection
    let artworkFraming: ArtworkFraming
    let transitionDuration: Double
    let mediaFilter: MediaFilter

    init(rows: Int, columns: Int, autoColumns: Bool, rotationInterval: Double,
         imageSource: ImageSourceType, showTitleReveal: Bool, titleDisplayDuration: Double,
         librarySelection: LibrarySelection, artworkFraming: ArtworkFraming = .fill,
         transitionDuration: Double = 1, mediaFilter: MediaFilter = MediaFilter()) {
        self.rows = min(10, max(1, rows))
        self.columns = min(10, max(1, columns))
        self.autoColumns = autoColumns
        self.rotationInterval = rotationInterval.isFinite ? min(120, max(2, rotationInterval)) : 5
        self.imageSource = imageSource
        self.showTitleReveal = showTitleReveal
        self.transitionDuration = min(self.rotationInterval - 0.5, transitionDuration.isFinite ? min(3, max(0.2, transitionDuration)) : 1)
        self.titleDisplayDuration = min(max(0.5, self.rotationInterval - self.transitionDuration), max(0.5, titleDisplayDuration.isFinite ? titleDisplayDuration : 2))
        self.librarySelection = librarySelection
        self.artworkFraming = artworkFraming
        self.mediaFilter = mediaFilter
    }

    /// Presets change presentation only, keeping the user's content choices.
    func applying(_ preset: PresentationPreset) -> SaverSettings {
        switch preset {
        case .mosaic:
            return SaverSettings(rows: 3, columns: 4, autoColumns: false, rotationInterval: 5,
                imageSource: .fanart, showTitleReveal: true, titleDisplayDuration: 2,
                librarySelection: librarySelection, artworkFraming: .fill, transitionDuration: 1, mediaFilter: mediaFilter)
        case .posterWall:
            return SaverSettings(rows: 2, columns: 6, autoColumns: true, rotationInterval: 10,
                imageSource: .posters, showTitleReveal: true, titleDisplayDuration: 2,
                librarySelection: librarySelection, artworkFraming: .fit, transitionDuration: 1, mediaFilter: mediaFilter)
        case .calm:
            return SaverSettings(rows: 1, columns: 1, autoColumns: false, rotationInterval: 60,
                imageSource: .fanart, showTitleReveal: false, titleDisplayDuration: 2,
                librarySelection: librarySelection, artworkFraming: .fit, transitionDuration: 2, mediaFilter: mediaFilter)
        }
    }
}

struct ConnectionSnapshot: Sendable {
    let provider: ProviderType
    let serverURL: String
    let token: String
    let userID: String
    let accountID: String
    let serverID: String
    let fallbackURLs: [String]
    let localFolderBookmark: Data?
    init(provider: ProviderType, serverURL: String, token: String, userID: String, accountID: String, serverID: String = "", fallbackURLs: [String] = [], localFolderBookmark: Data? = nil) {
        self.provider = provider; self.serverURL = serverURL; self.token = token; self.userID = userID; self.accountID = accountID; self.serverID = serverID; self.fallbackURLs = fallbackURLs; self.localFolderBookmark = localFolderBookmark
    }
    var profile: ConnectionProfile { ConnectionProfile(provider: provider, serverURL: serverURL, accountID: accountID, serverID: serverID) }
}
