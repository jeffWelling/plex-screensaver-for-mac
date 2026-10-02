import SwiftUI

@MainActor struct ConfigurationView: View {
    @ObservedObject var viewModel: ConfigurationViewModel
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Media server", selection: $viewModel.providerType) {
                        ForEach(ProviderType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.segmented)
                    if viewModel.providerType == .plex { plexAccount } else { jellyfinAccount }
                    if viewModel.isRestoring { ProgressView("Reading saved credentials…").controlSize(.small) }
                    if viewModel.usesHTTP {
                        Label("This HTTP connection sends sign-in credentials and artwork without encryption. Use an HTTPS server address where available.", systemImage: "lock.open")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    connectionStatus
                    if !viewModel.storageMessage.isEmpty {
                        Text(viewModel.storageMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        Button("Unlock saved credentials") { viewModel.retryCredentials() }.disabled(viewModel.isRestoring)
                    }
                } header: { Text("Connection") }

                Section {
                    HStack {
                        Stepper("Rows: \(viewModel.gridRows)", value: $viewModel.gridRows, in: 1...10)
                        Stepper("Columns: \(viewModel.gridColumns)", value: $viewModel.gridColumns, in: 1...10).disabled(viewModel.gridAutoColumns)
                    }
                    Toggle("Fit columns to each display", isOn: $viewModel.gridAutoColumns)
                    Picker("Artwork", selection: $viewModel.imageSource) {
                        ForEach(ImageSourceType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.segmented)
                    layoutPreview
                    LabeledContent("Delay between changes") {
                        Slider(value: $viewModel.rotationInterval, in: 2...30, step: 1) { Text("Delay between changes") }
                            .labelsHidden().accessibilityLabel("Delay between changes")
                            .accessibilityValue("\(Int(viewModel.rotationInterval)) seconds")
                        Text("\(Int(viewModel.rotationInterval)) s").monospacedDigit().frame(width: 40)
                    }
                    Toggle("Show title before each change", isOn: $viewModel.showTitleReveal)
                    if viewModel.showTitleReveal {
                        LabeledContent("Title duration") {
                            Slider(value: $viewModel.titleDisplayDuration, in: 0.5...max(0.5, viewModel.rotationInterval - 1), step: 0.5) { Text("Title duration") }
                                .labelsHidden().accessibilityLabel("Title duration")
                                .accessibilityValue("\(viewModel.titleDisplayDuration, specifier: "%.1f") seconds")
                            Text("\(viewModel.titleDisplayDuration, specifier: "%.1f") s").monospacedDigit().frame(width: 45)
                        }
                    }
                } header: { Text("Display") }

                Section {
                    Toggle("All libraries", isOn: $viewModel.allLibraries)
                    if !viewModel.discoveredLibraries.isEmpty {
                        ForEach(viewModel.discoveredLibraries) { library in
                            Toggle(library.name, isOn: viewModel.libraryBinding(for: library.id))
                        }
                    } else { Text("Connect and refresh to see available libraries.").font(.caption).foregroundStyle(.secondary) }
                    if !viewModel.allLibraries && viewModel.selectedLibraryIds.isEmpty {
                        Text("No libraries selected. Montage will show its setup message until you select a library.").font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Libraries") }

                Section {
                    Text(viewModel.cacheMessage.isEmpty ? "Artwork is cached for offline startup." : viewModel.cacheMessage).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Refresh artwork") { viewModel.refreshArtwork() }
                        Button("Clear cache") { viewModel.clearCache() }
                        Button("Copy diagnostics") { viewModel.copyDiagnostics() }.disabled(viewModel.diagnosticSummary.isEmpty)
                    }.disabled(viewModel.isManagingCache)
                    if viewModel.isManagingCache { ProgressView("Updating artwork cache…").controlSize(.small) }
                } header: { Text("Storage and diagnostics") }
            }
            .formStyle(.grouped)
            .disabled(viewModel.isApplying)
            Divider()
            HStack {
                if viewModel.isApplying { ProgressView().controlSize(.small); Text("Saving…").font(.caption) }
                Spacer()
                Button("Apply and Close") { viewModel.apply { onClose?() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.isApplying)
            }.padding(12)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 640)
        .onAppear { viewModel.refreshDiagnostics() }
        .onDisappear { viewModel.cancelPendingOperations() }
        .onChange(of: viewModel.rotationInterval) { _, interval in viewModel.titleDisplayDuration = min(viewModel.titleDisplayDuration, interval - 1) }
    }
    private var connectionStatus: some View {
        HStack {
            if viewModel.isTesting { ProgressView().controlSize(.small) }
            Text(viewModel.testMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
            Button("Test / Refresh") { viewModel.testConnection() }.disabled(viewModel.isTesting || !viewModel.isConnected || viewModel.isManagingCache)
        }
    }
    private var plexAccount: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isSignedIn {
                Text(viewModel.plexServerURL).font(.caption).textSelection(.enabled)
                HStack { Button("Change server") { viewModel.changeServer() }; Button("Sign out") { viewModel.signOut() } }
            } else if !viewModel.discoveredServers.isEmpty {
                ForEach(viewModel.discoveredServers) { server in
                    Button { viewModel.selectServer(server) } label: { Label(server.name, systemImage: "server.rack") }
                }
            } else {
                HStack {
                    Button("Sign in with Plex") { viewModel.signInWithPlex() }.disabled(viewModel.isSigningIn)
                    if viewModel.isSigningIn {
                        ProgressView().controlSize(.small)
                        Button("Cancel sign-in") { viewModel.cancelPendingOperations() }
                    }
                }
            }
            if !viewModel.signInStatus.isEmpty { Text(viewModel.signInStatus).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var jellyfinAccount: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isJellyfinConnected {
                Text("\(viewModel.jellyfinUsername) · \(viewModel.jellyfinServerURL)").font(.caption).textSelection(.enabled)
                Button("Disconnect") { viewModel.disconnectJellyfin() }
            } else {
                TextField("Server address", text: $viewModel.jellyfinServerURL).textFieldStyle(.roundedBorder)
                    .help("An HTTPS Jellyfin address, including a server subpath if needed")
                TextField("Username", text: $viewModel.jellyfinUsername).textFieldStyle(.roundedBorder)
                SecureField("Password", text: $viewModel.jellyfinPassword).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Connect") { viewModel.connectToJellyfin() }
                        .disabled(viewModel.isJellyfinConnecting || viewModel.jellyfinServerURL.isEmpty || viewModel.jellyfinUsername.isEmpty || viewModel.jellyfinPassword.isEmpty)
                    if viewModel.isJellyfinConnecting {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { viewModel.cancelPendingOperations() }
                    }
                }
            }
            if !viewModel.jellyfinStatus.isEmpty { Text(viewModel.jellyfinStatus).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var layoutPreview: some View {
        GeometryReader { geometry in
            let columns = viewModel.gridAutoColumns
                ? GridManager.autoColumns(width: geometry.size.width, height: geometry.size.height, rows: viewModel.gridRows, targetAspect: viewModel.imageSource == .posters ? 2.0 / 3.0 : 16.0 / 9.0)
                : viewModel.gridColumns
            VStack(spacing: 2) {
                ForEach(0..<viewModel.gridRows, id: \.self) { _ in
                    HStack(spacing: 2) {
                        ForEach(0..<columns, id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.35)) }
                    }
                }
            }
        }
        .frame(height: 90)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Grid layout preview")
        .accessibilityValue(viewModel.gridAutoColumns ? "\(viewModel.gridRows) rows with columns fitted to each display" : "\(viewModel.gridRows) rows and \(viewModel.gridColumns) columns")
    }
}
