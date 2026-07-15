// swift-tools-version: 6.0
import PackageDescription

// Test-only Swift package. It compiles the existing PlexSaver sources (the same
// files the Xcode `.saver` and SaverTest targets build — no duplication) into a
// `MontageCore` library so `MontageCoreTests` can `@testable import` them and
// run via `swift test`. The Xcode project remains the shipping build; this
// package exists solely to give the reservation logic and pure helpers unit
// coverage (A1). Swift 5 language mode matches the Xcode target's SWIFT_VERSION.
let package = Package(
    name: "MontageCore",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "MontageCore",
            path: "PlexSaver",
            exclude: [
                "Info.plist",
                "Resources",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MontageCoreTests",
            dependencies: ["MontageCore"],
            path: "Tests/MontageCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
