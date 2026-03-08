//
//  Logger.swift
//  PlexSaver
//

import Foundation
import os.log

extension OSLog {
    static let screenSaver = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "Montage", category: "Screensaver")

    static func info(_ message: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        os_log("MO (P:%d): %{public}@", log: .screenSaver, type: .default, pid, message)
    }
}
