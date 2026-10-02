import Foundation
import os.log

extension OSLog {
    static var screenSaver: OSLog { OSLog(subsystem: AppConstants.module, category: "Screensaver") }

    /// Legacy messages remain private; new structured events expose only stable
    /// categories and numeric diagnostics, never server addresses or credentials.
    static func info(_ message: String) {
        os_log("Montage pid:%d %{private}@", log: screenSaver, type: .info,
               ProcessInfo.processInfo.processIdentifier, message)
    }
    static func event(_ name: StaticString, detail: String = "", level: OSLogType = .info) {
        os_log("Montage %{public}@ pid:%d %{private}@", log: screenSaver, type: level,
               String(describing: name), ProcessInfo.processInfo.processIdentifier, detail)
    }
    static func metric(_ name: StaticString, value: Int) {
        os_log("Montage %{public}@ value:%d pid:%d", log: screenSaver, type: .debug,
               String(describing: name), value, ProcessInfo.processInfo.processIdentifier)
    }
}
