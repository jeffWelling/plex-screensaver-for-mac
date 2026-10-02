import Foundation

/// Optional work scales back before the system has to throttle the host.
struct PlaybackRuntimePolicy: Equatable, Sendable {
    let pausesPlayback: Bool
    let allowsNetwork: Bool
    let prefetchLimit: Int?
    let minimumRotationInterval: TimeInterval
    let maximumTransitionDuration: TimeInterval?
    let refreshInterval: TimeInterval

    static let normal = PlaybackRuntimePolicy(pausesPlayback: false, allowsNetwork: true,
                                               prefetchLimit: nil, minimumRotationInterval: 0,
                                               maximumTransitionDuration: nil, refreshInterval: 300)

    static func resolve(lowPower: Bool, thermalState: ProcessInfo.ThermalState) -> PlaybackRuntimePolicy {
        switch thermalState {
        case .critical:
            return PlaybackRuntimePolicy(pausesPlayback: true, allowsNetwork: false, prefetchLimit: 0,
                                         minimumRotationInterval: 60, maximumTransitionDuration: 0,
                                         refreshInterval: 900)
        case .serious:
            return PlaybackRuntimePolicy(pausesPlayback: false, allowsNetwork: false, prefetchLimit: 1,
                                         minimumRotationInterval: 30, maximumTransitionDuration: 0.2,
                                         refreshInterval: 900)
        case .fair:
            return reduced
        case .nominal:
            return lowPower ? reduced : normal
        @unknown default:
            return reduced
        }
    }

    private static var reduced: PlaybackRuntimePolicy {
        PlaybackRuntimePolicy(pausesPlayback: false, allowsNetwork: true, prefetchLimit: 1,
                              minimumRotationInterval: 15, maximumTransitionDuration: 0.2,
                              refreshInterval: 900)
    }
}
