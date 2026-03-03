//
//  ConfigurationView.swift
//  PlexSaver
//

import SwiftUI

struct ConfigurationView: View {
    @StateObject private var viewModel = ConfigurationViewModel()
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    GroupBox("Plex Account") {
                        VStack(alignment: .leading, spacing: 8) {
                            if viewModel.isSignedIn {
                                signedInView
                            } else if !viewModel.discoveredServers.isEmpty {
                                serverPickerView
                            } else {
                                signInView
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if viewModel.isSignedIn {
                        if let result = viewModel.testResult {
                            GroupBox("Connection") {
                                connectionView(result: result)
                            }
                        }

                        GroupBox("Grid Layout") {
                            gridLayoutView
                        }

                        GroupBox("Timing") {
                            timingView
                        }

                        GroupBox("Image Source") {
                            imageSourceView
                        }

                        if !viewModel.discoveredLibraries.isEmpty {
                            GroupBox("Libraries") {
                                librariesView
                            }
                        }
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") {
                    onClose?()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .frame(width: 480, height: 520)
        .background(Color(nsColor: NSColor.windowBackgroundColor))
    }

    // MARK: - Subviews

    private var signedInView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(viewModel.plexServerURL)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change Server") {
                    viewModel.changeServer()
                }
                Button("Sign Out") {
                    viewModel.signOut()
                }
            }

            if !viewModel.signInStatus.isEmpty {
                Text(viewModel.signInStatus)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
    }

    private var serverPickerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select a server:")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(viewModel.discoveredServers) { server in
                Button {
                    viewModel.selectServer(server)
                } label: {
                    HStack {
                        Image(systemName: "server.rack")
                        VStack(alignment: .leading) {
                            Text(server.name)
                            Text(server.uri)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if server.isLocal {
                            Text("Local")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var signInView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    viewModel.signInWithPlex()
                } label: {
                    HStack {
                        Image(systemName: "person.badge.key")
                        Text("Sign in with Plex")
                    }
                }
                .disabled(viewModel.isSigningIn)

                if viewModel.isSigningIn {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }
            }

            if !viewModel.signInStatus.isEmpty {
                Text(viewModel.signInStatus)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
    }

    private func connectionView(result: Bool) -> some View {
        HStack {
            Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(result ? .green : .red)
            Text(viewModel.testMessage)
                .foregroundColor(.secondary)

            Spacer()

            if viewModel.isTesting {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            }

            Button("Retest") {
                viewModel.testConnection()
            }
        }
    }

    private var gridLayoutView: some View {
        VStack {
            Stepper("Rows: \(viewModel.gridRows)", value: $viewModel.gridRows, in: 1...10)
            Stepper("Columns: \(viewModel.gridColumns)", value: $viewModel.gridColumns, in: 1...10)

            Text("\(viewModel.gridRows * viewModel.gridColumns) cells total")
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timingView: some View {
        HStack {
            Text("Rotation interval:")
            Slider(value: $viewModel.rotationInterval, in: 2...30, step: 1)
            Text("\(Int(viewModel.rotationInterval))s")
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var imageSourceView: some View {
        Picker("Source:", selection: $viewModel.imageSource) {
            ForEach(ImageSourceType.allCases, id: \.self) { source in
                Text(source.displayName).tag(source)
            }
        }
        .pickerStyle(.segmented)
    }

    private var librariesView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Select libraries to include:")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(viewModel.discoveredLibraries) { library in
                Toggle(isOn: viewModel.libraryBinding(for: library.key)) {
                    HStack {
                        Text(library.title)
                        Text("(\(library.type))")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
        }
    }
}
