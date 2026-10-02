import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import MontageCore

private actor FixtureTransport: NetworkTransport {
    let handler: @Sendable (URLRequest) throws -> Data
    private var requests: [URLRequest] = []

    init(handler: @escaping @Sendable (URLRequest) throws -> Data) { self.handler = handler }

    func data(for request: URLRequest, maximumBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        requests.append(request)
        let data = try handler(request)
        guard data.count <= maximumBytes else { throw MediaNetworkError.oversizedPayload }
        return data
    }

    func capturedRequests() -> [URLRequest] { requests }
}

final class NetworkTests: XCTestCase {
    func testEndpointPreservesProxyPathCaseAndEscapesQueryValues() throws {
        let endpoint = try ServerEndpoint("  HTTPS://HOST:8096/Jellyfin///  ")
        XCTAssertEqual(endpoint.canonicalURLString, "https://host:8096/Jellyfin")
        let url = try endpoint.url(path: "/Items/x/Images/Primary?tag=a%2Bb", query: [
            URLQueryItem(name: "url", value: "/art?x=1+2&y=a=b"),
            URLQueryItem(name: "maxWidth", value: "300")
        ])
        XCTAssertEqual(url.path, "/Jellyfin/Items/x/Images/Primary")
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(values.first?.value, "a+b")
        XCTAssertEqual(values[1].value, "/art?x=1+2&y=a=b")
        XCTAssertTrue(url.absoluteString.contains("%2B"))
    }

    func testEndpointRejectsInvalidOrCredentialBearingURLs() {
        for value in ["host:8096", "ftp://host", "https://user:password@host", "https://host?token=x", "https://host/#fragment", "https://host:99999", ""] {
            XCTAssertThrowsError(try ServerEndpoint(value), value)
        }
        XCTAssertFalse(try! ServerEndpoint("http://host").isSecure)
        XCTAssertThrowsError(try ServerEndpoint("https://host").url(path: "https://other/art"))
        XCTAssertThrowsError(try ServerEndpoint("https://host").url(path: "//other/art"))
    }

    func testTypedStatusErrors() throws {
        let url = URL(string: "https://fixture.invalid")!
        for (status, expected) in [(401, MediaNetworkError.authenticationRequired), (403, .authenticationRequired), (404, .missingArtwork), (410, .missingArtwork), (500, .unavailable), (302, .httpError(302))] {
            XCTAssertThrowsError(try MediaNetworkError.check(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)) {
                XCTAssertEqual($0 as? MediaNetworkError, expected)
            }
        }
        XCTAssertThrowsError(try MediaNetworkError.check(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "900"])!)) {
            XCTAssertEqual($0 as? MediaNetworkError, .throttled(retryAfter: 300))
        }
        XCTAssertNoThrow(try MediaNetworkError.check(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    }

    func testEphemeralBoundedSessionAndRedirectPolicy() {
        let config = URLSessionTransport.configuration()
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertEqual(config.timeoutIntervalForRequest, 15)
        XCTAssertEqual(config.timeoutIntervalForResource, 45)
        let origin = URL(string: "https://host:443/a")!
        XCTAssertTrue(RequestSecurityPolicy.allowsRedirect(from: origin, to: URL(string: "https://host:443/b")!))
        XCTAssertFalse(RequestSecurityPolicy.allowsRedirect(from: origin, to: URL(string: "http://host:443/b")!))
        XCTAssertFalse(RequestSecurityPolicy.allowsRedirect(from: origin, to: URL(string: "https://other:443/b")!))
    }

    func testCredentialRejectsHeaderInjection() {
        for value in ["", "good\r\nX-Token: bad", "bad\"quoted", "bad\\slash", "a b"] {
            XCTAssertThrowsError(try validatedCredential(value))
        }
        XCTAssertEqual(try! validatedCredential("abc-._~123"), "abc-._~123")
    }

    func testPlexRequestsHeadersAndPaginates() async throws {
        let first = (0..<500).map { ["ratingKey": String($0), "title": "Item \($0)"] }
        let firstData = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": first, "totalSize": 501]])
        let lastData = Data("{\"MediaContainer\":{\"Metadata\":[{\"ratingKey\":\"500\",\"title\":\"Last\"}],\"totalSize\":501}}".utf8)
        let fixture = FixtureTransport { request in
            let start = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "X-Plex-Container-Start" }?.value
            return start == "0" ? firstData : lastData
        }
        let items = try await PlexClient(serverURL: "https://fixture.invalid/Plex", token: "token", transport: fixture).fetchAllItems(sectionId: "A+B")
        XCTAssertEqual(items.count, 501)
        let requests = await fixture.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Plex-Token"), "token")
        XCTAssertEqual(requests.first?.url?.path, "/Plex/library/sections/A+B/all")
        XCTAssertEqual(URLComponents(url: requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems?.first?.value, "500")
    }

    func testPlexPaginationContinuesAfterShortPageWhenTotalAdvertisesMore() async throws {
        let firstData = Data("{\"MediaContainer\":{\"Metadata\":[{\"ratingKey\":\"1\",\"title\":\"First\"}],\"totalSize\":2}}".utf8)
        let lastData = Data("{\"MediaContainer\":{\"Metadata\":[{\"ratingKey\":\"2\",\"title\":\"Last\"}],\"totalSize\":2}}".utf8)
        let fixture = FixtureTransport { request in
            let start = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "X-Plex-Container-Start" }?.value
            return start == "0" ? firstData : lastData
        }
        let items = try await PlexClient(serverURL: "https://fixture.invalid", token: "token", transport: fixture).fetchAllItems(sectionId: "lib")
        XCTAssertEqual(items.map(\.ratingKey), ["1", "2"])
        let requests = await fixture.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(URLComponents(url: requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems?.first?.value, "1")
    }

    func testPlexFallbackUsesAdvertisedHTTPSAndDoesNotFallbackOnAuthFailure() async throws {
        let fixture = FixtureTransport { request in
            if request.url?.host == "failed.invalid" { throw MediaNetworkError.unavailable }
            guard request.url?.host == "working.invalid" else {
                XCTFail("Insecure fallback must not be used")
                throw MediaNetworkError.unavailable
            }
            return Data("{\"MediaContainer\":{\"Directory\":[]}}".utf8)
        }
        let client = PlexClient(serverURL: "https://failed.invalid", token: "token",
                                fallbackURLs: ["http://insecure.invalid", "https://working.invalid"], transport: fixture)
        _ = try await client.fetchLibraries()
        let requests = await fixture.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.url?.host, "working.invalid")
        let denied = FixtureTransport { _ in throw MediaNetworkError.authenticationRequired }
        do {
            _ = try await PlexClient(serverURL: "https://failed.invalid", token: "expired",
                                     fallbackURLs: ["https://working.invalid"], transport: denied).fetchLibraries()
            XCTFail("Expected credential failure")
        } catch {
            XCTAssertEqual(error as? MediaNetworkError, .authenticationRequired)
        }
        let deniedRequests = await denied.capturedRequests()
        XCTAssertEqual(deniedRequests.count, 1)
    }

    func testJellyfinRequestEscapingAndAuthorization() async throws {
        let fixture = FixtureTransport { _ in Data("{\"Items\":[],\"TotalRecordCount\":0}".utf8) }
        _ = try await JellyfinClient(serverURL: "https://fixture.invalid/Jellyfin", accessToken: "abc", userId: "user+one", transport: fixture).fetchAllItems(libraryId: "lib+1&other")
        let request = await fixture.capturedRequests().first!
        XCTAssertEqual(request.url?.path, "/Jellyfin/Users/user+one/Items")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first?.value, "lib+1&other")
        XCTAssertEqual(query.first { $0.name == "Fields" }?.value, "PrimaryImageAspectRatio,Genres")
        XCTAssertEqual(query.first { $0.name == "EnableUserData" }?.value, "true")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.contains("Token=\"abc\""))
        XCTAssertFalse(request.value(forHTTPHeaderField: "Authorization")!.contains("Version=\"1.0\""))
    }

    func testJellyfinAuthSendsJSONAndPreservesProxyPath() async throws {
        let fixture = FixtureTransport { _ in Data("{\"User\":{\"Id\":\"u\",\"Name\":\"Test\"},\"AccessToken\":\"abc\"}".utf8) }
        let result = try await JellyfinAuth(transport: fixture).authenticate(serverURL: "https://fixture.invalid/Jellyfin", username: "name", password: "temporary")
        XCTAssertEqual(result.userId, "u")
        let request = await fixture.capturedRequests().first!
        XCTAssertEqual(request.url?.path, "/Jellyfin/Users/AuthenticateByName")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
        XCTAssertEqual(body, ["Username": "name", "Pw": "temporary"])
        XCTAssertFalse(request.value(forHTTPHeaderField: "Authorization")!.contains("Token="))
    }

    func testJellyfinArtworkIdentityChangesWithTag() throws {
        let first = try JSONDecoder().decode(JellyfinItem.self, from: Data("{\"Id\":\"a\",\"Name\":\"A\",\"Type\":\"Movie\",\"ImageTags\":{\"Primary\":\"v1\"},\"BackdropImageTags\":[\"b1\"]}".utf8)).toMediaItem()
        let changed = try JSONDecoder().decode(JellyfinItem.self, from: Data("{\"Id\":\"a\",\"Name\":\"A\",\"Type\":\"Movie\",\"ImageTags\":{\"Primary\":\"v2\"},\"BackdropImageTags\":[\"b2\"]}".utf8)).toMediaItem()
        XCTAssertNotEqual(first.artPaths[.posters], changed.artPaths[.posters])
        XCTAssertEqual(first.artPaths[.fanart], "/Items/a/Images/Backdrop/0?tag=b1")
    }

    func testDiscoveryUsesReachableSecureConnectionAndStableServerID() async throws {
        let resources = Data("""
        [{"name":"Home","provides":"server","clientIdentifier":"physical-id","accessToken":"token","connections":[
          {"uri":"https://a.invalid","local":true,"protocol":"https"},
          {"uri":"https://b.invalid","local":false,"protocol":"https"},
          {"uri":"http://c.invalid","local":true,"protocol":"http"}]}]
        """.utf8)
        let fixture = FixtureTransport { request in
            if request.url?.host == "plex.tv" { return resources }
            if request.url?.host == "a.invalid" { throw MediaNetworkError.unavailable }
            if request.url?.host == "b.invalid" { return Data("<MediaContainer/>".utf8) }
            XCTFail("Never probe an insecure fallback")
            return Data()
        }
        let servers = try await PlexAuth(transport: fixture).discoverServers(authToken: "auth")
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.id, "physical-id")
        XCTAssertEqual(servers.first?.uri, "https://b.invalid")
        XCTAssertEqual(servers.first?.connections.count, 2)
    }

    func testPlexAccountIdentityIsStableAcrossTokenRotation() async throws {
        let fixture = FixtureTransport { request in
            switch request.value(forHTTPHeaderField: "X-Plex-Token") {
            case "first-token": return Data("{\"id\":42,\"authToken\":\"first-token\"}".utf8)
            case "rotated-token": return Data("{\"id\":42,\"authToken\":\"rotated-token\"}".utf8)
            default: throw MediaNetworkError.authenticationRequired
            }
        }
        let auth = PlexAuth(transport: fixture)
        let first = try await auth.fetchAccountID(authToken: "first-token")
        let rotated = try await auth.fetchAccountID(authToken: "rotated-token")
        XCTAssertEqual(first, "42")
        XCTAssertEqual(rotated, first)
        let requests = await fixture.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url?.absoluteString, "https://plex.tv/api/v2/user")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Product"), "Montage")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier"))
        }
    }

    func testPlexAccountIdentityCanonicalizesStringIDsAndRejectsInvalidProfiles() async throws {
        let valid = FixtureTransport { _ in Data("{\"id\":\"00042\"}".utf8) }
        let accountID = try await PlexAuth(transport: valid).fetchAccountID(authToken: "token")
        XCTAssertEqual(accountID, "42")
        for payload in ["{}", "{\"id\":null}", "{\"id\":0}", "{\"id\":-1}", "{\"id\":1.5}", "{\"id\":\"\"}", "{\"id\":\"user\"}"] {
            let fixture = FixtureTransport { _ in Data(payload.utf8) }
            do {
                _ = try await PlexAuth(transport: fixture).fetchAccountID(authToken: "token")
                XCTFail("Expected invalid profile for \(payload)")
            } catch {
                XCTAssertEqual(error as? MediaNetworkError, .invalidResponse)
            }
        }
        let denied = FixtureTransport { _ in throw MediaNetworkError.authenticationRequired }
        do {
            _ = try await PlexAuth(transport: denied).fetchAccountID(authToken: "expired")
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(error as? MediaNetworkError, .authenticationRequired)
        }
    }

    func testPINCreationAndPollingCancellation() async throws {
        let fixture = FixtureTransport { _ in Data("{\"id\":1,\"code\":\"1234\"}".utf8) }
        let auth = PlexAuth(transport: fixture)
        let pin = try await auth.createPin()
        XCTAssertEqual(pin.code, "1234")
        let request = await fixture.capturedRequests().first!
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier"))
        let task = Task { try await auth.pollForToken(pinId: 1, code: "1234") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        let afterCancellation = await fixture.capturedRequests()
        XCTAssertEqual(afterCancellation.count, 1)
    }

    func testPINPollingHasWallClockDeadlineAndCancelsPendingWork() async throws {
        let fixture = FixtureTransport { _ in Data("{\"id\":1,\"code\":\"1234\"}".utf8) }
        let auth = PlexAuth(transport: fixture, pollingTimeout: .milliseconds(20))
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await auth.pollForToken(pinId: 1, code: "1234", maxAttempts: 120)
            XCTFail("Expected authentication timeout")
        } catch PlexAuthError.timeout {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
        // The deadline wins while the polling task is sleeping, before it can
        // make a request. Its cancellation must prevent a late request.
        let requests = await fixture.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testDecoderPreparesBoundedArtworkAndRejectsInvalidData() throws {
        let context = CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let image = try ArtworkDecoder.decode(output as Data, width: 20, height: 16)
        XCTAssertEqual(image.size.width, 20)
        XCTAssertEqual(image.size.height, 16)
        XCTAssertThrowsError(try ArtworkDecoder.decode(Data("garbage".utf8), width: 20, height: 16))
        XCTAssertThrowsError(try ArtworkDecoder.decode(output as Data, width: 100_000, height: 16))
    }
}
