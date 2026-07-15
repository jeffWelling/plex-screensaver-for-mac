//
//  InstanceTracker.swift
//  PlexSaver
//

import Foundation

class InstanceTracker {
    static let shared = InstanceTracker()
    static var isRunningInApp: Bool = false

    private let queue = DispatchQueue(label: "montage.instance.tracker", qos: .utility)
    private var instanceCounter = 0

    private init() {}

    /// Returns a stable, monotonically increasing instance number used only to
    /// disambiguate log lines from concurrent `MontageView` instances.
    func registerInstance() -> Int {
        return queue.sync {
            instanceCounter += 1
            return instanceCounter
        }
    }
}
