import Foundation

/// Tracks active displays for fair small-library layout and private diagnostics.
final class InstanceTracker: @unchecked Sendable {
    static let shared = InstanceTracker()
    static var isRunningInApp: Bool {
        ProcessInfo.processInfo.processName == "SaverTest"
            || Bundle.main.bundleIdentifier == "com.montage.SaverTest"
    }
    private let lock = NSLock()
    private var nextNumber = 0
    private var activeInstances: Set<Int> = []
    private init() {}
    func registerInstance() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextNumber += 1
        return nextNumber
    }
    func setActive(_ active: Bool, instance: Int) {
        lock.lock()
        let changed: Bool
        if active { changed = activeInstances.insert(instance).inserted }
        else { changed = activeInstances.remove(instance) != nil }
        lock.unlock()
        if changed { NotificationCenter.default.post(name: .montageDisplaysChanged, object: nil) }
    }
    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeInstances.count
    }
}

extension Notification.Name {
    static let montageDisplaysChanged = Notification.Name("com.montage.active-displays-changed")
}
