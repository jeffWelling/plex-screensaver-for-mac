//
//  ConfigurationView.swift
//  PlexSaver
//

import SwiftUI

struct ConfigurationView: View {
    @StateObject private var viewModel = ConfigurationViewModel()
    var onClose: (() -> Void)?

    private var isConnected: Bool {
        (viewModel.providerType == .plex && viewModel.isSignedIn)
            || (viewModel.providerType == .jellyfin && viewModel.isJellyfinConnected)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Provider picker
                    Picker("Media Server", selection: $viewModel.providerType) {
                        ForEach(ProviderType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 4)

                    // Plex Account
                    if viewModel.providerType == .plex {
                        sectionHeader("Plex Account")
                        if viewModel.isSignedIn {
                            signedInView
                        } else if !viewModel.discoveredServers.isEmpty {
                            serverPickerView
                        } else {
                            signInView
                        }
                    }

                    // Jellyfin Server
                    if viewModel.providerType == .jellyfin {
                        sectionHeader("Jellyfin Server")
                        if viewModel.isJellyfinConnected {
                            jellyfinConnectedView
                        } else {
                            jellyfinLoginView
                        }
                    }

                    if isConnected {
                        if let result = viewModel.testResult {
                            connectionView(result: result)
                        }

                        Divider()

                        // Display
                        sectionHeader("Display")
                        gridLayoutView
                        timingView
                        titleRevealView
                        imageSourceView

                        if !viewModel.discoveredLibraries.isEmpty {
                            Divider()
                            sectionHeader("Libraries")
                            librariesView
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") {
                    onClose?()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 420, height: 400)
        .background(Color(nsColor: NSColor.windowBackgroundColor))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.primary)
    }

    // MARK: - Subviews

    private var signedInView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(viewModel.plexServerURL)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                if !viewModel.signInStatus.isEmpty {
                    Text(viewModel.signInStatus)
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                Spacer()
                Button("Change Server") {
                    viewModel.changeServer()
                }
                Button("Sign Out") {
                    viewModel.signOut()
                }
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
        HStack(spacing: 16) {
            Stepper("Rows: \(viewModel.gridRows)", value: $viewModel.gridRows, in: 1...10)
            Stepper("Cols: \(viewModel.gridColumns)", value: $viewModel.gridColumns, in: 1...10)
            Spacer()
            Text("\(viewModel.gridRows * viewModel.gridColumns) cells")
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }

    private var timingView: some View {
        HStack {
            Text("Delay between changes:")
            Slider(value: $viewModel.rotationInterval, in: 2...30, step: 1)
            Text("\(Int(viewModel.rotationInterval))s")
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var titleRevealView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Show title before rotation", isOn: $viewModel.showTitleReveal)

            if viewModel.showTitleReveal {
                HStack {
                    Text("Title duration:")
                    Slider(
                        value: $viewModel.titleDisplayDuration,
                        in: 1...max(1, viewModel.rotationInterval - 1),
                        step: 0.5
                    )
                    Text("\(String(format: "%.1f", viewModel.titleDisplayDuration))s")
                        .monospacedDigit()
                        .frame(width: 35, alignment: .trailing)
                }
            }
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
                Toggle(isOn: viewModel.libraryBinding(for: library.id)) {
                    HStack {
                        Text(library.name)
                        Text("(\(library.type))")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Jellyfin Subviews

    private var jellyfinLoginView: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Server URL", text: $viewModel.jellyfinServerURL)
                .textFieldStyle(.roundedBorder)
                .help("e.g. http://jellyfin.local:8096")

            TextField("Username", text: $viewModel.jellyfinUsername)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $viewModel.jellyfinPassword)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Connect") {
                    viewModel.connectToJellyfin()
                }
                .disabled(viewModel.isJellyfinConnecting
                    || viewModel.jellyfinServerURL.isEmpty
                    || viewModel.jellyfinUsername.isEmpty
                    || viewModel.jellyfinPassword.isEmpty)

                if viewModel.isJellyfinConnecting {
                    ProgressView()
                        .controlSize(.small)
                }

                if !viewModel.jellyfinStatus.isEmpty {
                    Text(viewModel.jellyfinStatus)
                        .font(.caption)
                        .foregroundColor(viewModel.isJellyfinConnected ? .green : .red)
                }
            }
        }
    }

    private var jellyfinConnectedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(viewModel.jellyfinServerURL)
                    .font(.caption)
                Text("(\(viewModel.jellyfinUsername))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button("Disconnect") {
                viewModel.disconnectJellyfin()
            }
        }
    }
}
