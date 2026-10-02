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
            let paths = [
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Screen Savers/Montage.saver"),
                URL(fileURLWithPath: "/Library/Screen Savers/Montage.saver")
            ]
            guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw OptionsError.missingSaver
            }
            let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let bundle = Bundle(url: path), bundle.bundleIdentifier == "com.montage.Montage" else {
                throw OptionsError.invalidSaver
            }
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
