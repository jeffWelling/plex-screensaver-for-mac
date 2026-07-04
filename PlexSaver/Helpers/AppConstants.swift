//
//  AppConstants.swift
//  PlexSaver
//

import Foundation

/// App-wide constants that must be stable across host processes.
enum AppConstants {
    /// Stable identifier used for the ScreenSaverDefaults preference domain, the
    /// disk-cache directory, and the Keychain service.
    ///
    /// This MUST be a hardcoded constant, not derived from `Bundle.main`. When
    /// the `.saver` bundle is loaded, `Bundle.main` resolves to the *host*
    /// process — System Settings for the configuration sheet, but
    /// `legacyScreenSaver` / `ScreenSaverEngine` for the running animation.
    /// Deriving the module name from `Bundle.main.bundleIdentifier` therefore
    /// opens *different* preference domains in the two contexts, so settings
    /// saved in the config UI would not be visible to the running screensaver.
    static let module = "com.montage.Montage"
}
