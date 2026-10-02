import AppKit
import CoreGraphics

@MainActor
enum SampleMode {
    static var offline = ProcessInfo.processInfo.arguments.contains("-MontageSimulateOffline")
    static var latency: Double = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-MontageSimulatedLatency"), args.indices.contains(index + 1) else { return 0 }
        return min(3, max(0, Double(args[index + 1]) ?? 0))
    }()
}

/// Development artwork requires no account and never contacts a media server.
actor SampleMediaProvider: MediaProvider {
    nonisolated let serverName = "Sample artwork"
    private let offline: Bool
    private let latency: Double
    init(offline: Bool = false, latency: Double = 0) {
        self.offline = offline
        self.latency = latency
    }
    private func wait() async throws {
        try Task.checkCancellation()
        if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        if offline { throw MediaNetworkError.unavailable }
    }
    func fetchLibraries() async throws -> [MediaLibrary] {
        try await wait()
        return [MediaLibrary(id: "samples", name: "Sample artwork", type: "movies")]
    }
    func fetchItems(libraryId: String) async throws -> [MediaItem] {
        try await wait()
        return (1...48).map { index in
            MediaItem(id: "sample-\(index)", title: "Sample Movie \(index)", year: 2000 + index % 25,
                      artPaths: [.fanart: "/sample/\(index)/background", .posters: "/sample/\(index)/poster"],
                      libraryId: "samples")
        }
    }
    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        try await wait()
        let index = Int(path.split(separator: "/").dropFirst().first ?? "1") ?? 1
        let w = min(2048, max(8, width))
        let h = min(2048, max(8, height))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MediaNetworkError.invalidImageData
        }
        let r = CGFloat((index * 47) % 255) / 255
        let g = CGFloat((index * 79) % 255) / 255
        let b = CGFloat((index * 113) % 255) / 255
        let colors = [CGColor(red: r * 0.7 + 0.15, green: g * 0.7 + 0.15, blue: b * 0.7 + 0.15, alpha: 1),
                      CGColor(red: r * 0.2, green: g * 0.2, blue: b * 0.2, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: CGFloat(w), y: CGFloat(h)), options: [])
        }
        context.setFillColor(CGColor(gray: 1, alpha: 0.15))
        let radius = CGFloat(min(w, h)) * 0.65
        context.fillEllipse(in: CGRect(x: CGFloat(w) * 0.55 - radius / 2,
                                      y: CGFloat(h) * 0.5 - radius / 2, width: radius, height: radius))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.3))
        context.setLineWidth(CGFloat(min(w, h)) / 80)
        context.stroke(CGRect(x: CGFloat(w) * 0.08, y: CGFloat(h) * 0.1,
                              width: CGFloat(w) * 0.84, height: CGFloat(h) * 0.8))
        guard let image = context.makeImage() else { throw MediaNetworkError.invalidImageData }
        return NSImage(cgImage: image, size: NSSize(width: w, height: h))
    }
}
