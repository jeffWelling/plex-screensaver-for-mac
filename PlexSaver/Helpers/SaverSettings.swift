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

    init(rows: Int, columns: Int, autoColumns: Bool, rotationInterval: Double,
         imageSource: ImageSourceType, showTitleReveal: Bool, titleDisplayDuration: Double,
         librarySelection: LibrarySelection) {
        self.rows = min(10, max(1, rows))
        self.columns = min(10, max(1, columns))
        self.autoColumns = autoColumns
        self.rotationInterval = rotationInterval.isFinite ? min(30, max(2, rotationInterval)) : 5
        self.imageSource = imageSource
        self.showTitleReveal = showTitleReveal
        self.titleDisplayDuration = min(self.rotationInterval - 1, max(0.5, titleDisplayDuration.isFinite ? titleDisplayDuration : 2))
        self.librarySelection = librarySelection
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
    init(provider: ProviderType, serverURL: String, token: String, userID: String, accountID: String, serverID: String = "", fallbackURLs: [String] = []) {
        self.provider = provider; self.serverURL = serverURL; self.token = token; self.userID = userID; self.accountID = accountID; self.serverID = serverID; self.fallbackURLs = fallbackURLs
    }
    var profile: ConnectionProfile { ConnectionProfile(provider: provider, serverURL: serverURL, accountID: accountID, serverID: serverID) }
}
