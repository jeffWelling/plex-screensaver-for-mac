//
//  ConfigurationView.swift
//  PlexSaver
//

import SwiftUI

struct ConfigurationView: View {
    @StateObject private var viewModel = ConfigurationViewModel()
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Form {
                Section("Plex Account") {
                    if viewModel.isSignedIn {
                        // Signed in — show server info
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
                    } else if !viewModel.discoveredServers.isEmpty {
                        // Servers discovered — pick one
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
                    } else {
                        // Not signed in — show sign in button
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

                if viewModel.isSignedIn {
                    if let result = viewModel.testResult {
                        Section("Connection") {
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
                    }

                    Section("Grid Layout") {
                        Stepper("Rows: \(viewModel.gridRows)", value: $viewModel.gridRows, in: 1...10)
                        Stepper("Columns: \(viewModel.gridColumns)", value: $viewModel.gridColumns, in: 1...10)

                        Text("\(viewModel.gridRows * viewModel.gridColumns) cells total")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }

                    Section("Timing") {
                        HStack {
                            Text("Rotation interval:")
                            Slider(value: $viewModel.rotationInterval, in: 2...30, step: 1)
                            Text("\(Int(viewModel.rotationInterval))s")
                                .monospacedDigit()
                                .frame(width: 30, alignment: .trailing)
                        }
                    }

                    Section("Image Source") {
                        Picker("Source:", selection: $viewModel.imageSource) {
                            ForEach(ImageSourceType.allCases, id: \.self) { source in
                                Text(source.displayName).tag(source)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if !viewModel.discoveredLibraries.isEmpty {
                        Section("Libraries") {
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
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Close") {
                    onClose?()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .frame(width: 480, height: dynamicHeight)
        .background(Color(nsColor: NSColor.windowBackgroundColor))
    }

    private var dynamicHeight: CGFloat {
        if !viewModel.isSignedIn && viewModel.discoveredServers.isEmpty {
            return 220
        }
        if !viewModel.discoveredServers.isEmpty && !viewModel.isSignedIn {
            return CGFloat(220 + viewModel.discoveredServers.count * 50)
        }
        return viewModel.discoveredLibraries.isEmpty ? 480 : 620
    }
}
