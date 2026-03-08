//
//  MontageTestContentView.swift
//  SaverTest
//

import SwiftUI

struct MontageTestContentView: View {
    private let configSheetController = ConfigureSheetController()

    var body: some View {
        MontageRepresentable()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Preferences") {
                        showPreferences()
                    }
                }
            }
    }

    private func showPreferences() {
        if let configWindow = configSheetController.window {
            configWindow.makeKeyAndOrderFront(nil)
            configWindow.styleMask = [.closable, .titled, .miniaturizable]
        }
    }
}
