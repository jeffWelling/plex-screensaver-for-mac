import SwiftUI
import AppKit

struct MontageRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> MontageView {
        guard let view = MontageView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), isPreview: false) else {
            fatalError("Failed to create MontageView")
        }
        Task { @MainActor [weak view] in view?.startAnimation() }
        return view
    }
    func updateNSView(_ nsView: MontageView, context: Context) {}
    static func dismantleNSView(_ nsView: MontageView, coordinator: ()) { nsView.stopAnimation() }
}
