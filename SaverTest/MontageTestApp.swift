//
//  MontageTestApp.swift
//  SaverTest
//

import SwiftUI

@main
struct MontageTestApp: App {
    init() {
        InstanceTracker.isRunningInApp = true
    }

    var body: some Scene {
        WindowGroup {
            MontageTestContentView()
        }
        .defaultSize(width: 1280, height: 720)
    }
}
