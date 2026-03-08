//
//  Preferences.swift
//  PlexSaver
//

import Foundation
import ScreenSaver

enum ImageSourceType: String, Codable, CaseIterable {
    case fanart = "fanart"
    case posters = "posters"
    case mixed = "mixed"

    var displayName: String {
        switch self {
        case .fanart: return "Fanart (16:9)"
        case .posters: return "Posters (2:3)"
        case .mixed: return "Mixed"
        }
    }
}

struct Preferences {
    @SimpleStorage(key: "PlexServerURL", defaultValue: "")
    static var plexServerURL: String

    @SimpleStorage(key: "PlexToken", defaultValue: "")
    static var plexToken: String

    @SimpleStorage(key: "PlexAuthToken", defaultValue: "")
    static var plexAuthToken: String

    @SimpleStorage(key: "GridRows", defaultValue: 3)
    static var gridRows: Int

    @SimpleStorage(key: "GridColumns", defaultValue: 4)
    static var gridColumns: Int

    @SimpleStorage(key: "RotationInterval", defaultValue: 5.0)
    static var rotationInterval: Double

    @Storage(key: "ImageSource", defaultValue: .fanart)
    static var imageSource: ImageSourceType

    @Storage(key: "SelectedLibraryIds", defaultValue: [])
    static var selectedLibraryIds: [String]

    @SimpleStorage(key: "ShowTitleReveal", defaultValue: true)
    static var showTitleReveal: Bool

    @SimpleStorage(key: "TitleDisplayDuration", defaultValue: 2.0)
    static var titleDisplayDuration: Double
}

// MARK: - Property Wrappers

@propertyWrapper struct Storage<T: Codable> {
    private let key: String
    private let defaultValue: T
    private let module = Bundle.main.bundleIdentifier ?? "com.montage.Montage"

    init(key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: T {
        get {
            if let userDefaults = ScreenSaverDefaults(forModuleWithName: module) {
                guard let jsonString = userDefaults.string(forKey: key),
                      let jsonData = jsonString.data(using: .utf8),
                      let value = try? JSONDecoder().decode(T.self, from: jsonData) else {
                    return defaultValue
                }
                return value
            }
            return defaultValue
        }
        set {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            if let jsonData = try? encoder.encode(newValue),
               let jsonString = String(data: jsonData, encoding: .utf8),
               let userDefaults = ScreenSaverDefaults(forModuleWithName: module) {
                userDefaults.set(jsonString, forKey: key)
                userDefaults.synchronize()
            }
        }
    }
}

@propertyWrapper struct SimpleStorage<T> {
    private let key: String
    private let defaultValue: T
    private let module = Bundle.main.bundleIdentifier ?? "com.montage.Montage"

    init(key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: T {
        get {
            if let userDefaults = ScreenSaverDefaults(forModuleWithName: module) {
                return userDefaults.object(forKey: key) as? T ?? defaultValue
            }
            return defaultValue
        }
        set {
            if let userDefaults = ScreenSaverDefaults(forModuleWithName: module) {
                userDefaults.set(newValue, forKey: key)
                userDefaults.synchronize()
            }
        }
    }
}
