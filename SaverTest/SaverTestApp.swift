//
//  SaverTestApp.swift
//  SaverTest
//

import SwiftUI

@main
struct SaverTestApp: App {
    init() {
        InstanceTracker.isRunningInApp = true
    }

    var body: some Scene {
        WindowGroup {
            SaverTestContentView()
        }
        .defaultSize(width: 1280, height: 720)
    }
}
