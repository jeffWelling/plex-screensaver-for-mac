//
//  ConfigureSheetController.swift
//  PlexSaver
//

import Cocoa
import SwiftUI
import os.log

class ConfigureSheetController: NSObject {
    private(set) var window: NSWindow?
    private var hostingController: NSHostingController<ConfigurationView>?

    override init() {
        super.init()
        setupWindow()
    }

    private func setupWindow() {
        let configView = ConfigurationView { [weak self] in
            self?.closeConfigureSheet()
        }

        hostingController = NSHostingController(rootView: configView)

        window = NSWindow(contentViewController: hostingController!)
        window?.title = "PlexSaver Preferences"
        window?.styleMask = [.titled, .closable]
        window?.isReleasedWhenClosed = false
        window?.setContentSize(NSSize(width: 420, height: 400))
        window?.center()
        window?.delegate = self
    }

    private func closeConfigureSheet() {
        if let sheetParent = window?.sheetParent {
            sheetParent.endSheet(window!)
        } else {
            window?.close()
        }
    }
}

extension ConfigureSheetController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        OSLog.info("Configuration window closing — notifying screensaver to reload")
        NotificationCenter.default.post(name: .montageConfigChanged, object: nil)
    }
}
