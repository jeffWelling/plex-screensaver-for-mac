import AppKit
import SwiftUI

/// Embeds actual draft playback in the remotely hosted Options content. The
/// screensaver host forwards this view with the rest of the sheet's controls.
@MainActor struct ArtworkPreviewView: NSViewRepresentable {
    let settings: SaverSettings
    let connection: ConnectionSnapshot

    func makeCoordinator() -> ArtworkPreviewController { ArtworkPreviewController() }
    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 280))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.mount(in: container, settings: settings, connection: connection)
        return container
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(settings: settings, connection: connection)
    }
    static func dismantleNSView(_ view: NSView, coordinator: ArtworkPreviewController) {
        coordinator.stop()
    }
}

/// Owns a mounted renderer and coalesces edits without saving preferences,
/// touching credentials, or creating a helper-process window.
@MainActor final class ArtworkPreviewController {
    private(set) var saverView: MontageView?
    private var updateTask: Task<Void, Never>?
    private var lastSettings: SaverSettings?
    private var lastConnection: ConnectionSnapshot?
    private let makeView: @MainActor (NSRect) -> MontageView?

    init(makeView: (@MainActor (NSRect) -> MontageView?)? = nil) {
        self.makeView = makeView ?? { MontageView(frame: $0, isPreview: true) }
    }
    deinit { updateTask?.cancel() }
    func mount(in container: NSView, settings: SaverSettings, connection: ConnectionSnapshot) {
        stop()
        guard let view = makeView(container.bounds) else { return }
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        saverView = view; lastSettings = settings; lastConnection = connection
        view.configurePreview(settings: settings, connection: connection)
        view.startAnimation()
    }
    func update(settings: SaverSettings, connection: ConnectionSnapshot) {
        guard saverView != nil, lastSettings != settings || !sameConnection(connection) else { return }
        lastSettings = settings; lastConnection = connection
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.saverView?.configurePreview(settings: settings, connection: connection)
            self.updateTask = nil
        }
    }
    func stop() {
        updateTask?.cancel(); updateTask = nil
        saverView?.stopAnimation()
        saverView?.removeFromSuperview()
        saverView = nil; lastSettings = nil; lastConnection = nil
    }
    private func sameConnection(_ connection: ConnectionSnapshot) -> Bool {
        guard let previous = lastConnection else { return false }
        return previous.provider == connection.provider && previous.serverURL == connection.serverURL
            && previous.token == connection.token && previous.userID == connection.userID
            && previous.accountID == connection.accountID && previous.serverID == connection.serverID
            && previous.fallbackURLs == connection.fallbackURLs
            && previous.localFolderBookmark == connection.localFolderBookmark
    }
}
