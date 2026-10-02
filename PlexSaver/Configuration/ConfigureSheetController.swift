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
    private let makeViewModel: @MainActor () -> ConfigurationViewModel

    init(makeViewModel: (@MainActor () -> ConfigurationViewModel)? = nil) {
        self.makeViewModel = makeViewModel ?? { ConfigurationViewModel() }
        super.init()
        // Selector observers are removed automatically when their owner dies.
        NotificationCenter.default.addObserver(self, selector: #selector(sheetDidEnd(_:)),
                                               name: NSWindow.didEndSheetNotification, object: nil)
    }

    /// Remote hosts can request the hidden source window repeatedly before
    /// displaying it. Keep that presentation stable until an actual dismissal.
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
        viewModel?.cancelPendingOperations(); viewModel?.closeArtworkPreview()
        presentationID = UUID()
        let id = presentationID
        needsPreparation = false
        let model = makeViewModel()
        viewModel = model
        let view = ConfigurationView(viewModel: model) { [weak self] in self?.dismiss(presentation: id) }
        let host = NSHostingController(rootView: view)
        hostingController = host
        // The remote host changes both geometry and window style. A dismissed
        // window belongs to its finished presentation; do not reuse that state.
        let window = ConfigureSheetWindow(contentViewController: host)
        window.title = "Montage Options"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 620, height: 720))
        window.minSize = NSSize(width: 560, height: 540)
        window.center(); window.delegate = self
        backingWindow = window
    }
    private func dismiss(presentation id: UUID) {
        guard id == presentationID, !needsPreparation, let window = backingWindow else { return }
        viewModel?.cancelPendingOperations(); viewModel?.closeArtworkPreview()
        permitsClose = true
        if let parent = window.sheetParent {
            parent.endSheet(window)
            window.orderOut(nil)
        } else { window.close() }
        permitsClose = false
        finishPresentation(window)
    }
    private func finishPresentation(_ window: NSWindow) {
        guard window === backingWindow, !needsPreparation else { return }
        viewModel?.cancelPendingOperations(); viewModel?.closeArtworkPreview()
        // Delayed actions from the old content must not dismiss its successor.
        presentationID = UUID()
        needsPreparation = true
    }
    @objc private func sheetDidEnd(_ notification: Notification) {
        guard let parent = notification.object as? NSWindow, let window = backingWindow,
              window.sheetParent === parent, !parent.sheets.contains(where: { $0 === window }) else { return }
        // AppKit posts this while sheetParent still identifies the ended sheet.
        // Merely hiding/reparenting the source view does not end a presentation.
        finishPresentation(window)
    }
}

extension ConfigureSheetController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === backingWindow else { return true }
        if permitsClose { return true }
        let id = presentationID
        viewModel?.cancel { [weak self] in self?.dismiss(presentation: id) }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        finishPresentation(window)
    }
}
