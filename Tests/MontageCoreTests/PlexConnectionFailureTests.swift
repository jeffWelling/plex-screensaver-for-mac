import XCTest
@testable import MontageCore

private final class FailedRequestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let code = URLError.Code(rawValue: Int(request.url!.lastPathComponent)!)
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }
    override func stopLoading() {}
}

private actor ConnectionFailureTransport: NetworkTransport {
    let handler: @Sendable (URLRequest) throws -> Data
    private var requests: [URLRequest] = []

    init(handler: @escaping @Sendable (URLRequest) throws -> Data) { self.handler = handler }

    func data(for request: URLRequest, maximumBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        requests.append(request)
        return try handler(request)
    }

    func capturedRequests() -> [URLRequest] { requests }
}

final class PlexConnectionFailureTests: XCTestCase {
    func testTransportDistinguishesDNSFailuresAndPreservesCancellation() async {
        let configuration = URLSessionTransport.configuration()
        configuration.protocolClasses = [FailedRequestProtocol.self]
        let transport = URLSessionTransport(configuration: configuration)
        for code: URLError.Code in [.cannotFindHost, .dnsLookupFailed, .timedOut, .cancelled] {
            let request = URLRequest(url: URL(string: "https://fixture.invalid/\(code.rawValue)")!)
            do {
                _ = try await transport.data(for: request, maximumBytes: 1024)
                XCTFail("Expected request failure for \(code)")
            } catch {
                if code == .cancelled {
                    XCTAssertTrue(error is CancellationError)
                } else {
                    XCTAssertEqual(error as? MediaNetworkError,
                                   code == .timedOut ? .unavailable : .nameResolutionFailed)
                }
            }
        }
    }

    func testDNSFailureRetriesSecureAlternativeAndRemembersSuccessfulEndpoint() async throws {
        let transport = ConnectionFailureTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "server-token")
            if request.url?.host == "local.plex.direct" { throw MediaNetworkError.nameResolutionFailed }
            return Data("{\"MediaContainer\":{\"Directory\":[]}}".utf8)
        }
        let client = PlexClient(serverURL: "https://local.plex.direct:32400", token: "server-token",
                                fallbackURLs: ["http://10.11.13.4:32400", "https://remote.invalid:32400"],
                                transport: transport)
        _ = try await client.fetchLibraries()
        _ = try await client.fetchLibraries()
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.compactMap { $0.url?.host }, ["local.plex.direct", "remote.invalid", "remote.invalid"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.scheme == "https" })
    }

    func testUnavailableFallbackDoesNotHideSelectedEndpointsDNSErrorOrTryHTTP() async {
        let transport = ConnectionFailureTransport { request in
            if request.url?.host == "local.plex.direct" { throw MediaNetworkError.nameResolutionFailed }
            throw MediaNetworkError.unavailable
        }
        let client = PlexClient(serverURL: "https://local.plex.direct:32400", token: "server-token",
                                fallbackURLs: ["https://remote.invalid:32400", "http://10.11.13.4:32400"],
                                transport: transport)
        do {
            _ = try await client.fetchLibraries()
            XCTFail("Expected DNS failure")
        } catch {
            XCTAssertEqual(error as? MediaNetworkError, .nameResolutionFailed)
        }
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.scheme == "https" })
    }

    func testAuthenticationFailureFromFallbackRemainsActionable() async {
        let transport = ConnectionFailureTransport { request in
            if request.url?.host == "local.plex.direct" { throw MediaNetworkError.nameResolutionFailed }
            throw MediaNetworkError.authenticationRequired
        }
        let client = PlexClient(serverURL: "https://local.plex.direct:32400", token: "server-token",
                                fallbackURLs: ["https://remote.invalid:32400"], transport: transport)
        do {
            _ = try await client.fetchLibraries()
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(error as? MediaNetworkError, .authenticationRequired)
        }
    }
}
