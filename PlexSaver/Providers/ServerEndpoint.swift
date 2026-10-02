import Foundation

/// A validated origin plus an optional reverse-proxy base path. Only the host
/// is case-insensitive: `/Jellyfin` and `/jellyfin` may be different routes.
struct ServerEndpoint: Sendable, Equatable {
    let url: URL

    init(_ text: String) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw MediaNetworkError.invalidURL
        }
        parts.scheme = scheme
        parts.host = host.lowercased()
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        guard let url = parts.url else { throw MediaNetworkError.invalidURL }
        self.url = url
    }

    var canonicalURLString: String { url.absoluteString }
    var isSecure: Bool { url.scheme == "https" }

    func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let relative = URLComponents(string: path), relative.scheme == nil,
              relative.host == nil, relative.fragment == nil, !path.hasPrefix("//") else {
            throw MediaNetworkError.invalidURL
        }
        parts.percentEncodedPath += "/" + relative.percentEncodedPath.drop(while: { $0 == "/" })
        let items = (relative.queryItems ?? []) + query
        // URLComponents otherwise leaves '+' unescaped, which many media
        // servers interpret as a space in nested artwork URLs.
        parts.percentEncodedQuery = items.isEmpty ? nil : items.map {
            Self.queryEscape($0.name) + ($0.value.map { "=" + Self.queryEscape($0) } ?? "")
        }.joined(separator: "&")
        guard let result = parts.url else { throw MediaNetworkError.invalidURL }
        return result
    }

    static func pathComponent(_ value: String) -> String {
        queryEscape(value)
    }

    private static func queryEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
