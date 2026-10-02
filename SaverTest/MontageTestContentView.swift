import SwiftUI

struct MontageTestContentView: View {
    private let configSheetController = ConfigureSheetController()
    @State private var offline = SampleMode.offline
    @State private var latency = SampleMode.latency
    private var usesInstalledSettings: Bool {
        ProcessInfo.processInfo.arguments.contains("-MontageUseInstalledSettings")
    }
    var body: some View {
        MontageRepresentable()
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if !usesInstalledSettings {
                        Toggle("Offline", isOn: $offline)
                            .onChange(of: offline) { _, newValue in
                                SampleMode.offline = newValue
                                NotificationCenter.default.post(name: .montageConfigChanged, object: nil)
                            }
                        Menu("Connection delay") {
                            ForEach([0.0, 0.5, 1.0, 3.0], id: \.self) { value in
                                Button(value == 0 ? "No delay" : String(format: "%.1f seconds", value)) {
                                    latency = value
                                    SampleMode.latency = value
                                    NotificationCenter.default.post(name: .montageConfigChanged, object: nil)
                                }
                            }
                        }
                    }
                    Button("Restart") {
                        NotificationCenter.default.post(name: .montageConfigChanged, object: nil)
                    }
                    Button("Options") {
                        configSheetController.window?.makeKeyAndOrderFront(nil)
                    }
                }
            }
    }
}
