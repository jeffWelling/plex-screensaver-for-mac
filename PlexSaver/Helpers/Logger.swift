//
//  Logger.swift
//  PlexSaver
//

import Foundation
import os.log

extension OSLog {
    static let screenSaver = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "PlexSaver", category: "Screensaver")

    static func info(_ message: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        os_log("PS (P:%d): %{public}@", log: .screenSaver, type: .default, pid, message)
    }
}
