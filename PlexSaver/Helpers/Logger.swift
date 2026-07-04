//
//  Logger.swift
//  PlexSaver
//

import Foundation
import os.log

extension OSLog {
    static let screenSaver = OSLog(subsystem: AppConstants.module, category: "Screensaver")

    static func info(_ message: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Message is logged as private so that any server-derived string
        // (URLs, item titles, error text) is redacted in the unified log by
        // default, guarding against accidental credential leakage.
        os_log("MO (P:%d): %{private}@", log: .screenSaver, type: .default, pid, message)
    }
}
