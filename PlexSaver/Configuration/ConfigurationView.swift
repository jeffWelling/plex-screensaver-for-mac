import SwiftUI

@MainActor struct ConfigurationView: View {
    @ObservedObject var viewModel: ConfigurationViewModel
    var onClose: (() -> Void)?
    @State private var showsAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Artwork from", selection: $viewModel.providerType) {
                        ForEach(ProviderType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.segmented)
                    switch viewModel.providerType {
                    case .plex: plexAccount
                    case .jellyfin: jellyfinAccount
                    case .local: localFolder
                    }
                    if viewModel.isRestoring { ProgressView("Reading saved credentials…").controlSize(.small) }
                    if viewModel.usesHTTP {
                        Label("This HTTP connection sends sign-in credentials and artwork without encryption. Use an HTTPS server address where available.", systemImage: "lock.open")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    connectionStatus
                    if !viewModel.storageMessage.isEmpty {
                        Text(viewModel.storageMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        if viewModel.providerType != .local {
                            Button("Unlock saved credentials") { viewModel.retryCredentials() }.disabled(viewModel.isRestoring)
                        }
                    }
                } header: { Text("Artwork source") }

                Section {
                    HStack {
                        Text("Start with a style")
                        Spacer()
                        ForEach(PresentationPreset.allCases, id: \.self) { preset in
                            Button(preset.displayName) { viewModel.applyPreset(preset) }
                        }
                    }
                    Picker("Artwork", selection: $viewModel.imageSource) {
                        ForEach(ImageSourceType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Framing", selection: $viewModel.artworkFraming) {
                        Text("Fill frame").tag(ArtworkFraming.fill)
                        Text("Show full artwork").tag(ArtworkFraming.fit)
                    }.pickerStyle(.segmented)
                    HStack {
                        Text("Preview your unsaved changes with real artwork.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(viewModel.isPreviewing ? "Hide preview" : "Show live preview") { viewModel.showArtworkPreview() }
                            .disabled(!viewModel.isConnected && !viewModel.isPreviewing)
                    }
                    if viewModel.isPreviewing {
                        ArtworkPreviewView(settings: viewModel.draftSettings, connection: viewModel.currentConnection)
                            .frame(maxWidth: .infinity).frame(height: 280)
                            .accessibilityLabel("Live artwork preview using unsaved display settings")
                    }
                    DisclosureGroup("Advanced display controls", isExpanded: $showsAdvanced) {
                        HStack {
                            Stepper("Rows: \(viewModel.gridRows)", value: $viewModel.gridRows, in: 1...10)
                            Stepper("Columns: \(viewModel.gridColumns)", value: $viewModel.gridColumns, in: 1...10).disabled(viewModel.gridAutoColumns)
                        }
                        Toggle("Fit columns to each display", isOn: $viewModel.gridAutoColumns)
                        layoutPreview
                        LabeledContent("Delay between changes") {
                            Slider(value: $viewModel.rotationInterval, in: 2...120, step: 1) { Text("Delay between changes") }
                                .labelsHidden().accessibilityLabel("Delay between changes")
                                .accessibilityValue("\(Int(viewModel.rotationInterval)) seconds")
                            Text("\(Int(viewModel.rotationInterval)) s").monospacedDigit().frame(width: 45)
                        }
                        LabeledContent("Fade duration") {
                            Slider(value: $viewModel.transitionDuration, in: 0.2...min(3, viewModel.rotationInterval - 0.5), step: 0.1) { Text("Fade duration") }
                                .labelsHidden().accessibilityLabel("Fade duration")
                            Text("\(viewModel.transitionDuration, specifier: "%.1f") s").monospacedDigit().frame(width: 45)
                        }
                        Toggle("Show title before each change", isOn: $viewModel.showTitleReveal)
                        if viewModel.showTitleReveal {
                            LabeledContent("Title duration") {
                                Slider(value: $viewModel.titleDisplayDuration, in: 0.5...max(0.5, viewModel.rotationInterval - viewModel.transitionDuration), step: 0.5) { Text("Title duration") }
                                    .labelsHidden().accessibilityLabel("Title duration")
                                    .accessibilityValue("\(viewModel.titleDisplayDuration, specifier: "%.1f") seconds")
                                Text("\(viewModel.titleDisplayDuration, specifier: "%.1f") s").monospacedDigit().frame(width: 45)
                            }
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
                        Text("No libraries selected. Select a library to display artwork.").font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text(viewModel.providerType == .local ? "Folders" : "Libraries") }

                if viewModel.filterCapabilities.hasFilters {
                    Section {
                        if viewModel.filterCapabilities.supportsFavorites { Toggle("Favorites only", isOn: $viewModel.mediaFilter.favoritesOnly) }
                        if viewModel.filterCapabilities.supportsUnwatched { Toggle("Unwatched only", isOn: $viewModel.mediaFilter.unwatchedOnly) }
                        if viewModel.filterCapabilities.supportsGenres {
                            DisclosureGroup("Genres\(viewModel.mediaFilter.genres.isEmpty ? " · All" : " · \(viewModel.mediaFilter.genres.count) selected")") {
                                ForEach(Array(Set(viewModel.filterOptions.genres + viewModel.mediaFilter.genres)).sorted(), id: \.self) { genre in
                                    Toggle(genre, isOn: viewModel.genreBinding(genre))
                                }
                            }
                        }
                        if viewModel.filterCapabilities.supportsCollections {
                            DisclosureGroup("Collections\(viewModel.mediaFilter.collections.isEmpty ? " · All" : " · \(viewModel.mediaFilter.collections.count) selected")") {
                                ForEach(Array(Set(viewModel.filterOptions.collections + viewModel.mediaFilter.collections)).sorted(), id: \.self) { collection in
                                    Toggle(collection, isOn: viewModel.collectionBinding(collection))
                                }
                            }
                        }
                        Text("Within each list, any selected choice matches. Different filters are combined.").font(.caption).foregroundStyle(.secondary)
                        if !viewModel.filterStatus.isEmpty { Text(viewModel.filterStatus).font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button("Refresh available filters") { viewModel.refreshFilterOptions() }.disabled(!viewModel.isConnected)
                            Button("Reset filters") { viewModel.mediaFilter = MediaFilter() }
                        }
                    } header: { Text("Personalize selection") }
                }

                Section {
                    Text("\(viewModel.offlineReadiness.readyTitles) titles prepared for offline playback.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let date = viewModel.offlineReadiness.lastPreparedDate {
                        HStack(spacing: 4) { Text("Last preparation:"); Text(date, style: .relative); Text("ago") }.font(.caption).foregroundStyle(.secondary)
                    }
                    Text(viewModel.cacheMessage.isEmpty ? "Cached artwork remains available when your server is offline." : viewModel.cacheMessage)
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Prepare offline artwork") { viewModel.prepareForOffline() }.disabled(!viewModel.isConnected || viewModel.isManagingCache)
                        Button("Refresh artwork") { viewModel.refreshArtwork() }.disabled(!viewModel.isConnected || viewModel.isManagingCache)
                        Button("Clear cache") { viewModel.clearCache() }.disabled(viewModel.isManagingCache)
                    }
                    if let progress = viewModel.preparationProgress {
                        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                    } else if viewModel.isManagingCache { ProgressView("Updating artwork…").controlSize(.small) }
                    if viewModel.isManagingCache { Button("Cancel preparation") { viewModel.cancelArtworkPreparation() } }
                    if !viewModel.preparationMessage.isEmpty { Text(viewModel.preparationMessage).font(.caption).foregroundStyle(.secondary) }
                    Text("Preparation downloads up to 200 titles per run and keeps up to 512 MB. Refresh keeps existing artwork until a replacement downloads. Clear cache removes saved images immediately.").font(.caption).foregroundStyle(.secondary)
                    Button("Copy diagnostics") { viewModel.copyDiagnostics() }.disabled(viewModel.diagnosticSummary.isEmpty)
                } header: { Text("Offline artwork and storage") }
            }
            .formStyle(.grouped)
            .disabled(viewModel.isApplying)
            Divider()
            HStack {
                if viewModel.isApplying { ProgressView().controlSize(.small); Text("Saving…").font(.caption) }
                Spacer()
                Button("Cancel") { viewModel.cancel { onClose?() } }
                    .keyboardShortcut(.cancelAction).disabled(viewModel.isApplying)
                Button("Apply and Close") { viewModel.apply { onClose?() } }
                    .keyboardShortcut(.defaultAction).disabled(viewModel.isApplying)
            }.padding(12)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 720)
        .onAppear { viewModel.refreshDiagnostics() }
        .onDisappear { viewModel.cancelPendingOperations(); viewModel.closeArtworkPreview() }
        .onChange(of: viewModel.draftSettings) { _, _ in
            viewModel.refreshDiagnostics()
        }
        .onChange(of: viewModel.currentSelection) { _, _ in viewModel.refreshFilterOptions() }
        .onChange(of: viewModel.transitionDuration) { _, duration in
            viewModel.titleDisplayDuration = min(viewModel.titleDisplayDuration, max(0.5, viewModel.rotationInterval - duration))
        }
        .onChange(of: viewModel.rotationInterval) { _, interval in
            viewModel.titleDisplayDuration = min(viewModel.titleDisplayDuration, max(0.5, interval - viewModel.transitionDuration))
            viewModel.transitionDuration = min(viewModel.transitionDuration, interval - 0.5)
        }
    }
    private var connectionStatus: some View {
        HStack {
            if viewModel.isTesting { ProgressView().controlSize(.small) }
            Text(viewModel.testMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
            Button("Test / Refresh") { viewModel.testConnection() }.disabled(viewModel.isTesting || !viewModel.isConnected || viewModel.isManagingCache)
        }
    }
    private var localFolder: some View {
        HStack {
            Text(viewModel.localFolderName.isEmpty ? "Choose a folder of artwork." : viewModel.localFolderName).textSelection(.enabled)
            Spacer()
            Button(viewModel.localFolderBookmark == nil ? "Choose folder…" : "Change folder…") { viewModel.chooseLocalFolder() }
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
                        Button("Cancel connection") { viewModel.cancelPendingOperations() }
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
