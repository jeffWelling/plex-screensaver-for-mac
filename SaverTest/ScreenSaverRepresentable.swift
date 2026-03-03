//
//  ScreenSaverRepresentable.swift
//  SaverTest
//

import SwiftUI
import AppKit

struct ScreenSaverRepresentable: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PlexSaverView {
        guard let view = PlexSaverView(frame: NSZeroRect, isPreview: false) else {
            fatalError("Failed to create PlexSaverView")
        }
        context.coordinator.screenSaverView = view

        DispatchQueue.main.async {
            view.startAnimation()
        }

        return view
    }

    func updateNSView(_ nsView: PlexSaverView, context: Context) {
        nsView.needsDisplay = true
    }

    static func dismantleNSView(_ nsView: PlexSaverView, coordinator: Coordinator) {
        nsView.stopAnimation()
    }

    class Coordinator {
        var screenSaverView: PlexSaverView?
    }
}
