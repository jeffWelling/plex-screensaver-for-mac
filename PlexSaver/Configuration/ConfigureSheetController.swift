import Cocoa
import SwiftUI

@MainActor final class ConfigureSheetController: NSObject {
    private var backingWindow: NSWindow?
    private var viewModel: ConfigurationViewModel?
    private var hostingController: NSHostingController<ConfigurationView>?
    private var permitsClose = false
    private var presentationID = UUID()

    /// System Settings can reuse the controller across sheet presentations.
    /// Rebuild a hidden sheet so reopening restores saved settings and starts
    /// fresh cancellable library discovery instead of retaining old UI state.
    var window: NSWindow? {
        if backingWindow?.isVisible != true && viewModel?.isApplying != true { preparePresentation() }
        return backingWindow
    }
    private func preparePresentation() {
        viewModel?.cancelPendingOperations()
        presentationID = UUID()
        let id = presentationID
        let model = ConfigurationViewModel()
        viewModel = model
        let view = ConfigurationView(viewModel: model) { [weak self] in self?.dismissAfterApply(presentation: id) }
        let host = NSHostingController(rootView: view)
        hostingController = host
        if let window = backingWindow { window.contentViewController = host }
        else {
            let window = NSWindow(contentViewController: host)
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
    }
}

extension ConfigureSheetController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if permitsClose { return true }
        let id = presentationID
        viewModel?.apply { [weak self] in self?.dismissAfterApply(presentation: id) }
        return false
    }
    func windowWillClose(_ notification: Notification) { viewModel?.cancelPendingOperations() }
}
