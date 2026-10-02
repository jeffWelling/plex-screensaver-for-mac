import Foundation

enum AppConstants {
    static let productionModule = "com.montage.Montage"
    private static var saverBundle: Bundle { Bundle(for: MontageView.self) }
    static var version: String { saverBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development" }
    static var build: String { saverBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown" }
    /// Stable across screensaver hosts; development uses an isolated domain.
    static var module: String {
        #if SWIFT_PACKAGE
        return productionModule + ".tests.\(ProcessInfo.processInfo.processIdentifier)"
        #else
        let isolatedApp = Bundle.main.bundleIdentifier == "com.montage.SaverTest"
            || ProcessInfo.processInfo.processName == "SaverTest"
        return isolatedApp && !ProcessInfo.processInfo.arguments.contains("-MontageUseInstalledSettings")
            ? productionModule + ".development" : productionModule
        #endif
    }
}
