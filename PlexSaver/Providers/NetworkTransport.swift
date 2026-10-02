import AppKit
import ImageIO

/// Errors keep recovery decisions independent of Plex/Jellyfin wording.
enum MediaNetworkError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case invalidCredential
    case authenticationRequired
    case missingArtwork
    case throttled(retryAfter: TimeInterval?)
    case unavailable
    case httpError(Int)
    case invalidResponse
    case invalidImageData
    case oversizedPayload

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid http:// or https:// server URL without credentials, a query, or a fragment."
        case .invalidCredential: return "The saved credential is invalid. Please sign in again."
        case .authenticationRequired: return "Your media server rejected the credential. Please sign in again."
        case .missingArtwork: return "This artwork is no longer available."
        case .throttled: return "The media server is busy. Montage will retry shortly."
        case .unavailable: return "The media server is currently unreachable."
        case .httpError(let status): return "The media server returned HTTP \(status)."
        case .invalidResponse: return "The media server returned an unexpected response."
        case .invalidImageData: return "The media server returned invalid artwork."
        case .oversizedPayload: return "The media server response exceeds Montage's size limit."
        }
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Self.invalidResponse }
        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw Self.authenticationRequired
        case 404, 410: throw Self.missingArtwork
        case 429:
            let value = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                .flatMap { $0.isFinite ? $0 : nil }
            throw Self.throttled(retryAfter: value.map { min(300, max(1, $0)) })
        case 500...599: throw Self.unavailable
        default: throw Self.httpError(http.statusCode)
        }
    }
}

protocol NetworkTransport: Sendable {
    func data(for request: URLRequest, maximumBytes: Int) async throws -> Data
}

/// Does not persist cookies, HTTP credentials, or artwork into a host app's
/// cache. Both JSON and image requests have explicit deadlines and byte limits.
final class URLSessionTransport: NetworkTransport, @unchecked Sendable {
    private let session: URLSession
    static let maximumImageBytes = 16 * 1024 * 1024
    static let maximumJSONBytes = 32 * 1024 * 1024

    init(configuration: URLSessionConfiguration = URLSessionTransport.configuration()) {
        self.session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 45
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }

    func data(for request: URLRequest, maximumBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        guard maximumBytes > 0 else { throw MediaNetworkError.oversizedPayload }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RequestSecurityPolicy.shared)
            defer { bytes.task.cancel() }
            try MediaNetworkError.check(response)
            if response.expectedContentLength > maximumBytes { throw MediaNetworkError.oversizedPayload }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw MediaNetworkError.oversizedPayload }
                data.append(byte)
                if data.count % 16_384 == 0 { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return data
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw MediaNetworkError.unavailable
        }
    }
}

/// Never forwards tokens to another origin or follows an HTTPS downgrade.
/// Server trust uses the system verifier; no interactive authentication UI.
final class RequestSecurityPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RequestSecurityPolicy()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let target = request.url,
              Self.allowsRedirect(from: original, to: target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    static func allowsRedirect(from original: URL, to target: URL) -> Bool {
        original.scheme == target.scheme && original.host == target.host && original.port == target.port
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Actor clients invoke this off the main actor. The returned NSImage owns an
/// immediately decoded, bounded CGImage, avoiding lazy decoding during fades.
enum ArtworkDecoder {
    static func decode(_ data: Data, width: Int, height: Int) throws -> NSImage {
        try Task.checkCancellation()
        guard data.count <= URLSessionTransport.maximumImageBytes,
              width > 0, height > 0, width <= 8192, height <= 8192,
              let source = CGImageSourceCreateWithData(data as CFData,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              sourceWidth.intValue > 0, sourceHeight.intValue > 0,
              sourceWidth.intValue <= 32768, sourceHeight.intValue <= 32768,
              Int64(sourceWidth.intValue) * Int64(sourceHeight.intValue) <= 100_000_000 else {
            throw MediaNetworkError.invalidImageData
        }
        // Decode enough pixels for aspect-fill cropping, while capping the
        // decoded bitmap at 8 megapixels even for extreme source aspect ratios.
        let sourceW = sourceWidth.doubleValue
        let sourceH = sourceHeight.doubleValue
        let fillScale = max(Double(width) / sourceW, Double(height) / sourceH)
        let pixelScale = sqrt(8_000_000 / (sourceW * sourceH))
        let scale = min(1, fillScale, pixelScale, 8192 / max(sourceW, sourceH))
        let maximumDimension = max(1, Int(ceil(max(sourceW, sourceH) * scale)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MediaNetworkError.invalidImageData
        }
        try Task.checkCancellation()
        if image.bitsPerComponent > 8 {
            // High-bit-depth PNG/HDR sources would otherwise double decoded
            // memory despite the pixel cap. Convert only those sources to the
            // display cache's eight-bit format; ordinary artwork keeps its bitmap.
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw MediaNetworkError.invalidImageData
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let normalized = context.makeImage() else { throw MediaNetworkError.invalidImageData }
            try Task.checkCancellation()
            return PreparedArtwork.image(normalized)
        }
        return PreparedArtwork.image(image)
    }
}

/// Quoted header values must not contain separators or control characters.
func validatedCredential(_ value: String) throws -> String {
    guard !value.isEmpty, value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }),
          !value.contains("\""), !value.contains("\\") else { throw MediaNetworkError.invalidCredential }
    return value
}
