//
//  MontageRepresentable.swift
//  SaverTest
//

import SwiftUI
import AppKit

struct MontageRepresentable: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MontageView {
        guard let view = MontageView(frame: NSZeroRect, isPreview: false) else {
            fatalError("Failed to create MontageView")
        }
        context.coordinator.screenSaverView = view

        DispatchQueue.main.async {
            view.startAnimation()
        }

        return view
    }

    func updateNSView(_ nsView: MontageView, context: Context) {
        nsView.needsDisplay = true
    }

    static func dismantleNSView(_ nsView: MontageView, coordinator: Coordinator) {
        nsView.stopAnimation()
    }

    class Coordinator {
        var screenSaverView: MontageView?
    }
}
