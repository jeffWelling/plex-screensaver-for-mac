import Cocoa
import SwiftUI
import os.log

/// The screensaver host can remove the title style while embedding a sheet.
/// Options still needs keyboard focus for its controls in that borderless form.
@MainActor final class ConfigureSheetWindow: NSWindow {
    override var canBecomeKey: Bool {
        OSLog.metric("options.window.style", value: Int(styleMask.rawValue))
        return true
    }
}

@MainActor final class ConfigureSheetController: NSObject {
    private var backingWindow: NSWindow?
    private var viewModel: ConfigurationViewModel?
    private var hostingController: NSHostingController<ConfigurationView>?
    private var permitsClose = false
    private var presentationID = UUID()
    private var needsPreparation = true
    private let makeViewModel: () -> ConfigurationViewModel

    init(makeViewModel: @escaping () -> ConfigurationViewModel = { ConfigurationViewModel() }) {
        self.makeViewModel = makeViewModel
        super.init()
    }

    /// Remote hosts can request the hidden source window repeatedly before
    /// displaying it. Keep its content stable until an actual dismissal; the
    /// next presentation then restores saved settings with fresh discovery.
    var window: NSWindow? {
        if needsPreparation && backingWindow?.sheetParent == nil && backingWindow?.isVisible != true
            && viewModel?.isApplying != true { preparePresentation() }
        if let window = backingWindow {
            OSLog.event("options.requested")
            OSLog.metric("options.window.number", value: window.windowNumber)
            OSLog.metric("options.window.width", value: Int(window.frame.width))
            OSLog.metric("options.window.height", value: Int(window.frame.height))
            OSLog.metric("options.content.width", value: Int(window.contentView?.frame.width ?? 0))
            OSLog.metric("options.content.height", value: Int(window.contentView?.frame.height ?? 0))
        }
        return backingWindow
    }
    private func preparePresentation() {
        viewModel?.cancelPendingOperations()
        presentationID = UUID()
        let id = presentationID
        needsPreparation = false
        let model = makeViewModel()
        viewModel = model
        let view = ConfigurationView(viewModel: model) { [weak self] in self?.dismissAfterApply(presentation: id) }
        let host = NSHostingController(rootView: view)
        hostingController = host
        if let window = backingWindow { window.contentViewController = host }
        else {
            let window = ConfigureSheetWindow(contentViewController: host)
            window.title = "Montage Options"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 560, height: 640))
            window.minSize = NSSize(width: 520, height: 540)
            window.center(); window.delegate = self
            backingWindow = window
        }
    }
    private func dismissAfterApply(presentation id: UUID) {
        guard id == presentationID else { return }
        viewModel?.cancelPendingOperations()
        permitsClose = true
        if let window = backingWindow, let parent = window.sheetParent {
            parent.endSheet(window)
            window.orderOut(nil)
        } else { backingWindow?.close() }
        permitsClose = false
        needsPreparation = true
    }
}

extension ConfigureSheetController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if permitsClose { return true }
        let id = presentationID
        viewModel?.apply { [weak self] in self?.dismissAfterApply(presentation: id) }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        viewModel?.cancelPendingOperations()
        needsPreparation = true
    }
}
