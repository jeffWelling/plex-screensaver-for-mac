import AppKit

/// A separate preview uses draft settings and in-memory credentials, never
/// saves preferences, and stops the renderer before its window disappears.
@MainActor final class ArtworkPreviewController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var saverView: MontageView?
    private var updateTask: Task<Void, Never>?
    private let makeView: @MainActor (NSRect) -> MontageView?

    init(makeView: (@MainActor (NSRect) -> MontageView?)? = nil) {
        self.makeView = makeView ?? { MontageView(frame: $0, isPreview: true) }
    }
    deinit { updateTask?.cancel() }
    func show(settings: SaverSettings, connection: ConnectionSnapshot) {
        if window == nil {
            let rectangle = NSRect(x: 0, y: 0, width: 960, height: 540)
            guard let view = makeView(rectangle) else { return }
            view.autoresizingMask = [.width, .height]
            let preview = NSWindow(contentRect: rectangle, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            preview.title = "Montage Preview — Unsaved Changes"
            preview.isReleasedWhenClosed = false; preview.contentView = view
            preview.minSize = NSSize(width: 480, height: 300); preview.delegate = self; preview.center()
            saverView = view; window = preview
        }
        updateTask?.cancel(); updateTask = nil
        saverView?.configurePreview(settings: settings, connection: connection)
        saverView?.startAnimation()
        window?.makeKeyAndOrderFront(nil)
    }
    func update(settings: SaverSettings, connection: ConnectionSnapshot) {
        guard saverView != nil else { return }
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.window?.isVisible == true else { return }
            self.saverView?.configurePreview(settings: settings, connection: connection)
            self.updateTask = nil
        }
    }
    func close() {
        updateTask?.cancel(); updateTask = nil
        saverView?.stopAnimation()
        window?.orderOut(nil)
        window?.close()
        saverView = nil; window = nil
    }
    func windowWillClose(_ notification: Notification) {
        updateTask?.cancel(); updateTask = nil
        saverView?.stopAnimation()
        saverView = nil; window = nil
    }
}
