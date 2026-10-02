import AppKit

actor JellyfinClient {
    private let serverURL: String
    private let accessToken: String
    private let userId: String
    private let transport: any NetworkTransport

    init(serverURL: String, accessToken: String, userId: String,
         transport: any NetworkTransport = URLSessionTransport()) {
        self.serverURL = serverURL
        self.accessToken = accessToken
        self.userId = userId
        self.transport = transport
    }

    func fetchLibraries() async throws -> [JellyfinLibrary] {
        let data = try await request(path: "/Users/\(ServerEndpoint.pathComponent(userId))/Views")
        return try JSONDecoder().decode(JellyfinViewsResponse.self, from: data).items
    }

    func fetchAllItems(libraryId: String) async throws -> [JellyfinItem] {
        let pageSize = 500
        var startIndex = 0
        var items: [JellyfinItem] = []
        var seen = Set<String>()
        while true {
            try Task.checkCancellation()
            let data = try await request(path: "/Users/\(ServerEndpoint.pathComponent(userId))/Items", query: [
                URLQueryItem(name: "ParentId", value: libraryId),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,MusicAlbum"),
                URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio"),
                URLQueryItem(name: "StartIndex", value: String(startIndex)),
                URLQueryItem(name: "Limit", value: String(pageSize))
            ])
            let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
            let fresh = response.items.filter { seen.insert($0.id).inserted }
            items.append(contentsOf: fresh)
            startIndex += response.items.count
            if response.items.isEmpty || fresh.isEmpty || startIndex >= response.totalRecordCount { return items }
            guard startIndex <= 250_000 else { throw MediaNetworkError.oversizedPayload }
        }
    }

    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        let url = try ServerEndpoint(serverURL).url(path: path, query: [
            URLQueryItem(name: "maxWidth", value: String(width)),
            URLQueryItem(name: "maxHeight", value: String(height)),
            URLQueryItem(name: "format", value: "Jpg"),
            URLQueryItem(name: "quality", value: "90")
        ])
        var request = URLRequest(url: url)
        request.setValue(try JellyfinAuth.authorizationHeader(token: accessToken), forHTTPHeaderField: "Authorization")
        let data = try await transport.data(for: request, maximumBytes: URLSessionTransport.maximumImageBytes)
        return try ArtworkDecoder.decode(data, width: width, height: height)
    }

    private func request(path: String, query: [URLQueryItem] = []) async throws -> Data {
        let url = try ServerEndpoint(serverURL).url(path: path, query: query)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(try JellyfinAuth.authorizationHeader(token: accessToken), forHTTPHeaderField: "Authorization")
        return try await transport.data(for: request, maximumBytes: URLSessionTransport.maximumJSONBytes)
    }
}
