import AppKit

actor PlexClient {
    private var serverURL: String
    private let fallbackURLs: [String]
    private let token: String
    private let transport: any NetworkTransport

    init(serverURL: String, token: String, fallbackURLs: [String] = [], transport: any NetworkTransport = URLSessionTransport()) {
        self.serverURL = serverURL
        self.fallbackURLs = fallbackURLs
        self.token = token
        self.transport = transport
    }

    func fetchLibraries() async throws -> [PlexLibrary] {
        let data = try await request(path: "/library/sections")
        return try JSONDecoder().decode(PlexLibrarySectionsResponse.self, from: data).MediaContainer.Directory ?? []
    }

    func fetchAllItems(sectionId: String) async throws -> [PlexMediaItem] {
        let pageSize = 500
        var offset = 0
        var result: [PlexMediaItem] = []
        var seen = Set<String>()
        while true {
            try Task.checkCancellation()
            let data = try await request(path: "/library/sections/\(ServerEndpoint.pathComponent(sectionId))/all", query: [
                URLQueryItem(name: "X-Plex-Container-Start", value: String(offset)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(pageSize))
            ])
            let container = try JSONDecoder().decode(PlexMediaItemsResponse.self, from: data).MediaContainer
            let page = container.Metadata ?? []
            let fresh = page.filter { seen.insert($0.ratingKey).inserted }
            result.append(contentsOf: fresh)
            offset += page.count
            // Some Plex versions ignore pagination. Detect repeats rather than
            // issuing requests forever or duplicating the whole catalogue.
            if page.isEmpty || fresh.isEmpty || (container.totalSize == nil && page.count < pageSize) || offset >= (container.totalSize ?? Int.max) {
                return result
            }
            guard offset <= 250_000 else { throw MediaNetworkError.oversizedPayload }
        }
    }

    func fetchImage(imagePath: String, width: Int, height: Int) async throws -> NSImage {
        let data = try await request(path: "/photo/:/transcode", query: [
            URLQueryItem(name: "url", value: imagePath),
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "minSize", value: "1")
        ], maximumBytes: URLSessionTransport.maximumImageBytes)
        return try ArtworkDecoder.decode(data, width: width, height: height)
    }

    private func request(path: String, query: [URLQueryItem] = [],
                         maximumBytes: Int = URLSessionTransport.maximumJSONBytes) async throws -> Data {
        let active = try ServerEndpoint(serverURL)
        // Fallbacks are advertised connections to the same physical server.
        // An explicitly configured HTTP origin may upgrade, but an HTTPS origin
        // can never silently downgrade when it becomes unavailable.
        var endpoints = [active]
        for value in fallbackURLs {
            if let endpoint = try? ServerEndpoint(value), endpoint.isSecure, !endpoints.contains(endpoint) {
                endpoints.append(endpoint)
            }
        }
        let credential = try validatedCredential(token)
        for (index, endpoint) in endpoints.enumerated() {
            try Task.checkCancellation()
            var request = URLRequest(url: try endpoint.url(path: path, query: query))
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(credential, forHTTPHeaderField: "X-Plex-Token")
            do {
                let data = try await transport.data(for: request, maximumBytes: maximumBytes)
                try Task.checkCancellation()
                serverURL = endpoint.canonicalURLString
                return data
            } catch MediaNetworkError.unavailable where index < endpoints.count - 1 {
                continue
            }
        }
        throw MediaNetworkError.unavailable
    }
}
