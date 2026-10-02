import AppKit
import ScreenSaver

/// Open the installed saver’s own configuration UI without a remote Settings host.
@MainActor
final class MontageOptionsDelegate: NSObject, NSApplicationDelegate {
    private var saverBundle: Bundle?
    private var saverView: ScreenSaverView?
    private var optionsWindow: NSWindow?
    private var finishedClosing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        do {
            let bundle = try installedSaverBundle()
            try bundle.loadAndReturnError()
            guard let viewType = bundle.principalClass as? ScreenSaverView.Type,
                  let view = viewType.init(frame: NSRect(x: 0, y: 0, width: 320, height: 200), isPreview: true),
                  view.hasConfigureSheet, let window = view.configureSheet else {
                throw OptionsError.invalidSaver
            }
            // Retain the plugin and its controller. This view never starts playback;
            // the existing Options live preview is responsible for its own lifecycle.
            saverBundle = bundle
            saverView = view
            optionsWindow = window
            NotificationCenter.default.addObserver(self, selector: #selector(optionsDidClose(_:)),
                                                   name: NSWindow.willCloseNotification, object: window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Montage Options could not open"
            alert.informativeText = (error as? OptionsError)?.message
                ?? "The installed Montage screensaver could not be loaded. Reinstall Montage and try again."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        optionsWindow?.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !finishedClosing, let window = optionsWindow, window.isVisible else { return .terminateNow }
        // Use the saver’s close handling so Quit also cancels previews and drafts.
        window.performClose(nil)
        return .terminateCancel
    }

    @objc private func optionsDidClose(_ notification: Notification) {
        finishedClosing = true
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private func installedSaverBundle() throws -> Bundle {
        let directories = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Screen Savers", isDirectory: true),
            URL(fileURLWithPath: "/Library/Screen Savers", isDirectory: true)
        ]
        // Prefer a user installation, then choose its newest valid release. Reading
        // metadata here does not load any plugin code; only the winner is loaded.
        for directory in directories {
            let paths = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let candidates = paths.compactMap { InstalledSaver(url: $0) }
            if let latest = candidates.max(by: { first, second in
                if first.version != second.version {
                    return first.version.lexicographicallyPrecedes(second.version)
                }
                if first.build != second.build { return first.build < second.build }
                return first.filenamePriority < second.filenamePriority
            }) {
                return latest.bundle
            }
        }
        throw OptionsError.missingSaver
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Montage Options")
        appMenu.addItem(withTitle: "About Montage Options", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Montage Options", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        // Standard text-editing commands are needed for server addresses and sign-in.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}

/// Recognize only Montage's current and historical installation filenames.
private struct InstalledSaver {
    let bundle: Bundle
    let version: [Int]
    let build: Int
    let filenamePriority: Int

    init?(url: URL) {
        let filename = url.lastPathComponent
        let namedVersion: String?
        if filename == "Montage.saver" || filename == "PlexSaver.saver" {
            namedVersion = nil
            filenamePriority = 0
        } else if filename.hasPrefix("Montage v"), filename.hasSuffix(".saver") {
            namedVersion = String(filename.dropFirst("Montage v".count).dropLast(".saver".count))
            filenamePriority = 2
        } else if filename.hasPrefix("Montage_v"), filename.hasSuffix(".saver") {
            namedVersion = String(filename.dropFirst("Montage_v".count).dropLast(".saver".count))
            filenamePriority = 1
        } else {
            return nil
        }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let candidate = Bundle(url: url), candidate.bundleIdentifier == "com.montage.Montage",
              let versionString = candidate.infoDictionary?["CFBundleShortVersionString"] as? String,
              let releaseVersion = Self.releaseVersion(versionString),
              namedVersion == nil || namedVersion == versionString,
              let buildString = candidate.infoDictionary?["CFBundleVersion"] as? String,
              buildString.utf8.allSatisfy({ (48...57).contains($0) }),
              let releaseBuild = Int(buildString), releaseBuild >= 0 else {
            return nil
        }
        bundle = candidate
        version = releaseVersion
        build = releaseBuild
    }

    private static func releaseVersion(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }
}

private enum OptionsError: Error {
    case missingSaver, invalidSaver
    var message: String {
        switch self {
        case .missingSaver:
            return "Install Montage in your Library/Screen Savers folder before opening Options."
        case .invalidSaver:
            return "The installed Montage screensaver is invalid. Reinstall Montage and try again."
        }
    }
}

@main
@MainActor
enum MontageOptionsApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = MontageOptionsDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
