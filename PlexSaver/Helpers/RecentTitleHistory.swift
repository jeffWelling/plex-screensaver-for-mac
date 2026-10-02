import Foundation
import CryptoKit
import Darwin

/// Only hashed title identities are retained. History is optional for previews
/// and test runs, and each provider/server/account has an independent file.
actor RecentTitleHistory {
    static let maxEntries = 200
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private static let processLock = NSLock()
    private let directory: URL
    private let now: @Sendable () -> Date

    init(namespace: String, directory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppConstants.module, isDirectory: true)
            .appendingPathComponent("recent-titles-v1", isDirectory: true)
        self.directory = base.appendingPathComponent(Self.digest(namespace), isDirectory: true)
        self.now = now
    }

    nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func dates() -> [String: Date] { transaction { $0 } ?? [:] }

    func recordDisplayed(titleKey: String) {
        _ = transaction { entries in
            entries[Self.digest(titleKey)] = now()
            return ()
        }
    }

    private func transaction<T>(_ body: (inout [String: Date]) -> T) -> T? {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        let descriptor = open(directory.appendingPathComponent("history.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }
        let file = directory.appendingPathComponent("history.json")
        var entries = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        let oldest = now().addingTimeInterval(-Self.maxAge)
        entries = entries.filter { $0.value >= oldest && $0.value <= now().addingTimeInterval(60) }
        let result = body(&entries)
        if entries.count > Self.maxEntries {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value > $1.value }.prefix(Self.maxEntries).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
        return result
    }
}
