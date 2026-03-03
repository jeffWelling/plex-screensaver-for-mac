//
//  InstanceTracker.swift
//  PlexSaver
//

import Foundation

class InstanceTracker {
    static let shared = InstanceTracker()
    static var isRunningInApp: Bool = false

    private let queue = DispatchQueue(label: "plexsaver.instance.tracker", qos: .utility)
    private var instanceCounter = 0
    private var instances: [Int: WeakRef] = [:]

    private init() {}

    func registerInstance(_ instance: PlexSaverView) -> Int {
        return queue.sync {
            instanceCounter += 1
            instances[instanceCounter] = WeakRef(instance)
            return instanceCounter
        }
    }

    var totalInstances: Int {
        return queue.sync {
            instances = instances.filter { $0.value.value != nil }
            return instances.count
        }
    }
}

private class WeakRef {
    weak var value: PlexSaverView?

    init(_ value: PlexSaverView) {
        self.value = value
    }
}
