import ScreenSaver
import AppKit
import os.log

/// Each start has one immutable settings snapshot and one cancellable run.
/// Cached and downloaded candidates use the same pool and grid coordinator.
@MainActor
class MontageView: ScreenSaverView {
    lazy var configSheetController = ConfigureSheetController()
    private let instanceNumber: Int
    private var started = false
    private var generation = UUID()
    private var runTask: Task<Void, Never>?
    private var geometryTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    private var gridManager: GridManager?
    private var imagePool: ImagePool?
    private var settings: SaverSettings?
    private var statusLayer: CATextLayer?
    private var statusBackdrop: CALayer?
    private var statusIsCompact = false
    private var fadeLayer: CALayer?
    private var hudLayer: CATextLayer?
    private var observers: [NotificationObservation] = []
    private var requestPixelSize = CGSize.zero
    private var availableItems = 0

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override init?(frame: NSRect, isPreview: Bool) {
        instanceNumber = InstanceTracker.shared.registerInstance()
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        layer?.backgroundColor = CGColor.black
        // Core Animation renders fades. No per-frame CPU drawing is needed.
        animationTimeInterval = 60
        observers.append(NotificationObservation(center: .default, name: .montageConfigChanged) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        })
        observers.append(NotificationObservation(center: .default, name: .montageDisplaysChanged) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleGeometryRefresh() }
        })
        if !InstanceTracker.isRunningInApp {
            // An additional shutdown signal only; a plug-in never terminates
            // Apple's host process or infers preview state from private keys.
            observers.append(NotificationObservation(center: DistributedNotificationCenter.default(),
                                                      name: NSNotification.Name("com.apple.screensaver.willstop")) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stopAnimation() }
                })
        }
        observers.append(NotificationObservation(center: NSWorkspace.shared.notificationCenter,
                                                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] _ in
                MainActor.assumeIsolated { self?.gridManager?.updateAccessibilityAppearance() }
            })
        OSLog.event("view.created", detail: "instance=\(instanceNumber), preview=\(isPreview)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Montage requires frame initialization") }

    override var hasConfigureSheet: Bool { true }
    override var configureSheet: NSWindow? { configSheetController.window }

    override func startAnimation() {
        guard !started else { return }
        super.startAnimation()
        started = true
        InstanceTracker.shared.setActive(true, instance: instanceNumber)
        let run = UUID()
        generation = run
        let snapshot = Preferences.settingsSnapshot()
        settings = snapshot
        buildGrid(settings: snapshot)
        showStatus("Starting Montage…")
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.run(settings: snapshot, generation: run)
        }
        startHUD(run: run)
        OSLog.event("run.started", detail: "instance=\(instanceNumber)")
    }

    override func stopAnimation() {
        super.stopAnimation()
        guard started else { return }
        started = false
        generation = UUID()
        InstanceTracker.shared.setActive(false, instance: instanceNumber)
        runTask?.cancel()
        runTask = nil
        geometryTask?.cancel()
        geometryTask = nil
        statusTask?.cancel()
        statusTask = nil
        hudTask?.cancel()
        hudTask = nil
        gridManager?.stopRotation()
        gridManager?.rootLayer.removeFromSuperlayer()
        gridManager = nil
        fadeLayer?.removeAllAnimations()
        fadeLayer?.removeFromSuperlayer()
        fadeLayer = nil
        removeStatus()
        hudLayer?.removeFromSuperlayer()
        hudLayer = nil
        let pool = imagePool
        imagePool = nil
        settings = nil
        availableItems = 0
        requestPixelSize = .zero
        if let pool { Task { await pool.stop() } }
        OSLog.event("run.stopped", detail: "instance=\(instanceNumber)")
    }

    private func restart() {
        guard started else { return }
        stopAnimation()
        startAnimation()
    }

    private func isCurrent(_ run: UUID) -> Bool { started && generation == run && !Task.isCancelled }

    private func run(settings: SaverSettings, generation run: UUID) async {
        do {
            let provider: any MediaProvider
            let namespace: String
            if InstanceTracker.isRunningInApp && !ProcessInfo.processInfo.arguments.contains("-MontageUseInstalledSettings") {
                provider = SampleMediaProvider(offline: SampleMode.offline, latency: SampleMode.latency)
                namespace = "\(AppConstants.module).sample-v1"
            } else {
                let connection = try await Preferences.connectionSnapshot()
                guard isCurrent(run) else { return }
                guard !connection.serverURL.isEmpty else {
                    showStatus("Open Options to connect your media server.")
                    return
                }
                let endpoint = try ServerEndpoint(connection.serverURL)
                guard !connection.token.isEmpty else {
                    showStatus("Open Options to connect your media server.")
                    return
                }
                namespace = connection.profile.cacheNamespace
                switch connection.provider {
                case .plex: provider = PlexProvider(serverURL: endpoint.canonicalURLString, token: connection.token, fallbackURLs: connection.fallbackURLs)
                case .jellyfin:
                    guard !connection.userID.isEmpty else {
                        showStatus("Open Options to reconnect Jellyfin.")
                        return
                    }
                    provider = JellyfinProvider(serverURL: endpoint.canonicalURLString,
                                                accessToken: connection.token, userId: connection.userID)
                }
            }
            guard isCurrent(run) else { return }
            if case .selected(let ids) = settings.librarySelection, ids.isEmpty {
                showStatus("No libraries selected. Choose a library in Options.")
                return
            }
            let cache = await DiskCacheCoordinator.shared.cache(for: namespace)
            guard isCurrent(run) else { return }
            let pixelWidth = max(1, min(8192, Int((gridManager?.cellWidth ?? 480) * backingScale)))
            let pixelHeight = max(1, min(8192, Int((gridManager?.cellHeight ?? 270) * backingScale)))
            requestPixelSize = CGSize(width: pixelWidth, height: pixelHeight)
            let pool = ImagePool(provider: provider, namespace: namespace, imageSource: settings.imageSource,
                                 includePostersInMixed: settings.imageSource == .mixed,
                                 cellWidth: pixelWidth, cellHeight: pixelHeight,
                                 poolSize: min(24, max(2, gridManager?.cells.count ?? 12)),
                                 diskCache: cache)
            imagePool = pool
            let restored = await pool.restoreCachedImages(selection: settings.librarySelection)
            guard isCurrent(run) else { await pool.stop(); return }
            if restored > 0 {
                await adaptGridIfNeeded(settings: settings, availableItems: restored, pool: pool, run: run)
                guard isCurrent(run) else { await pool.stop(); return }
                gridManager?.startRotation(imagePool: pool)
                OSLog.metric("startup.cached_candidates", value: restored)
            }
            await refresh(pool: pool, settings: settings, generation: run, retryDelay: 30)
        } catch is CancellationError {
            OSLog.event("run.cancelled")
        } catch {
            guard isCurrent(run) else { return }
            showStatus(error.localizedDescription + "\nOpen Options to check your connection.")
            OSLog.event("run.failed", detail: error.localizedDescription, level: .error)
        }
    }

    /// Each refresh is finite. The wait between attempts holds a weak view so
    /// the host can discard it even when it omits a final stop callback.
    private func refresh(pool: ImagePool, settings: SaverSettings, generation run: UUID,
                         retryDelay: Double) async {
        guard isCurrent(run) else { return }
        let itemCount = await pool.loadMediaItems(selection: settings.librarySelection)
        guard isCurrent(run) else { return }
        availableItems = itemCount
        let loadError = await pool.lastLoadError
        if presentAuthenticationError(loadError) { return }
        if itemCount > 0 {
            await adaptGridIfNeeded(settings: settings, availableItems: itemCount, pool: pool, run: run)
            guard isCurrent(run) else { return }
            let filled = await pool.prefill(count: 1)
            guard isCurrent(run) else { return }
            if presentAuthenticationError(await pool.lastLoadError) { return }
            gridManager?.startRotation(imagePool: pool)
            if loadError == nil && (filled > 0 || (gridManager?.occupiedCellCount ?? 0) > 0) {
                removeStatus()
                scheduleRefresh(after: 300, pool: pool, settings: settings, run: run, retryDelay: 30)
                return
            }
        }
        if (gridManager?.occupiedCellCount ?? 0) > 0 {
            showStatus("Offline · showing saved artwork", compact: true)
            dismissStatus(after: 4, run: run)
        } else {
            showStatus("Artwork is unavailable. Montage will retry automatically.")
        }
        OSLog.event("connection.retry", detail: "seconds=\(Int(retryDelay)), items=\(itemCount)")
        scheduleRefresh(after: retryDelay, pool: pool, settings: settings, run: run,
                        retryDelay: min(300, retryDelay * 2))
    }

    private func presentAuthenticationError(_ error: MediaNetworkError?) -> Bool {
        guard error == .authenticationRequired || error == .invalidCredential else { return false }
        let hasArtwork = (gridManager?.occupiedCellCount ?? 0) > 0
        let suffix = hasArtwork ? " Saved artwork will continue." : ""
        showStatus("Sign-in has expired. Reconnect in Options." + suffix, compact: hasArtwork)
        return true
    }

    private func scheduleRefresh(after delay: Double, pool: ImagePool, settings: SaverSettings,
                                 run: UUID, retryDelay: Double) {
        runTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, self.isCurrent(run) else { return }
            await self.refresh(pool: pool, settings: settings, generation: run, retryDelay: retryDelay)
        }
    }

    private func buildGrid(settings: SaverSettings, dimensions: (rows: Int, columns: Int)? = nil) {
        gridManager?.stopRotation()
        gridManager?.rootLayer.removeFromSuperlayer()
        fadeLayer?.removeFromSuperlayer()
        let columns = settings.autoColumns
            ? GridManager.autoColumns(width: bounds.width, height: bounds.height, rows: settings.rows,
                                      targetAspect: settings.imageSource == .posters ? 2.0 / 3.0 : 16.0 / 9.0)
            : settings.columns
        let manager = GridManager(frame: bounds, rows: dimensions?.rows ?? settings.rows,
                                  columns: dimensions?.columns ?? columns,
                                  rotationInterval: settings.rotationInterval,
                                  showTitleReveal: settings.showTitleReveal,
                                  titleDisplayDuration: settings.titleDisplayDuration,
                                  backingScale: backingScale)
        layer?.addSublayer(manager.rootLayer)
        gridManager = manager
        let fade = CALayer()
        fade.frame = bounds
        fade.backgroundColor = CGColor.black
        layer?.addSublayer(fade)
        fadeLayer = fade
        let run = generation
        manager.onFirstArtwork = { [weak self, weak fade] in
            guard let self, self.isCurrent(run), let fade else { return }
            self.removeStatus()
            CATransaction.begin()
            CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.2 : 0.6)
            CATransaction.setCompletionBlock { [weak fade] in
                Task { @MainActor in fade?.removeFromSuperlayer() }
            }
            fade.opacity = 0
            CATransaction.commit()
        }
    }

    private func adaptGridIfNeeded(settings: SaverSettings, availableItems: Int, pool: ImagePool,
                                   run: UUID) async {
        let dimensions = desiredDimensions(settings: settings, availableItems: availableItems)
        guard gridManager?.cells.count != dimensions.rows * dimensions.columns else { return }
        buildGrid(settings: settings, dimensions: dimensions)
        let width = max(1, min(8192, Int((gridManager?.cellWidth ?? 480) * backingScale)))
        let height = max(1, min(8192, Int((gridManager?.cellHeight ?? 270) * backingScale)))
        await pool.updateRequestSize(width: width, height: height)
        guard isCurrent(run) else { return }
        requestPixelSize = CGSize(width: width, height: height)
    }

    private func desiredDimensions(settings: SaverSettings, availableItems: Int) -> (rows: Int, columns: Int) {
        let columns = settings.autoColumns
            ? GridManager.autoColumns(width: bounds.width, height: bounds.height, rows: settings.rows,
                                      targetAspect: settings.imageSource == .posters ? 2.0 / 3.0 : 16.0 / 9.0)
            : settings.columns
        guard availableItems > 0 else { return (settings.rows, columns) }
        return GridManager.adaptiveDimensions(rows: settings.rows, columns: columns,
                                              availableItems: availableItems,
                                              displayCount: max(1, InstanceTracker.shared.activeCount))
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        NSBezierPath(rect: bounds).fill()
    }
    override func animateOneFrame() {}

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        gridManager?.updateFrame(bounds)
        fadeLayer?.frame = bounds
        layoutStatus()
        scheduleGeometryRefresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        gridManager?.updateBackingScale(backingScale)
        scheduleGeometryRefresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        gridManager?.updateBackingScale(backingScale)
        scheduleGeometryRefresh()
    }

    private func scheduleGeometryRefresh() {
        guard started, bounds.width > 0, bounds.height > 0 else { return }
        geometryTask?.cancel()
        let run = generation
        geometryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            guard let self, self.isCurrent(run), let settings = self.settings else { return }
            let width = (self.gridManager?.cellWidth ?? 0) * self.backingScale
            let height = (self.gridManager?.cellHeight ?? 0) * self.backingScale
            let widthChange = abs(width - self.requestPixelSize.width) / max(1, self.requestPixelSize.width)
            let heightChange = abs(height - self.requestPixelSize.height) / max(1, self.requestPixelSize.height)
            let dimensions = self.desiredDimensions(settings: settings, availableItems: self.availableItems)
            let desiredCount = dimensions.rows * dimensions.columns
            let gridCount = self.gridManager?.cells.count ?? 0
            if widthChange > 0.2 || heightChange > 0.2 || (self.availableItems > 0 && gridCount != desiredCount) {
                self.restart()
            }
        }
    }

    private func showStatus(_ text: String, compact: Bool = false) {
        statusTask?.cancel()
        removeStatus()
        let backdrop = CALayer()
        backdrop.backgroundColor = CGColor(gray: 0, alpha: 0.85)
        backdrop.cornerRadius = 8
        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.font = NSFont.systemFont(ofSize: compact ? 14 : 18)
        textLayer.fontSize = compact ? 14 : 18
        textLayer.contentsScale = backingScale
        textLayer.foregroundColor = CGColor.white
        textLayer.alignmentMode = .center
        textLayer.isWrapped = true
        layer?.addSublayer(backdrop)
        layer?.addSublayer(textLayer)
        statusLayer = textLayer
        statusBackdrop = backdrop
        statusIsCompact = compact
        layoutStatus()
    }

    private func layoutStatus() {
        let compact = statusIsCompact
        let width = max(0, min(520, bounds.width - 32))
        let height: CGFloat = compact ? 36 : 88
        let y = compact ? 24 : max(0, (bounds.height - height) / 2)
        statusBackdrop?.frame = CGRect(x: (bounds.width - width) / 2, y: y, width: width, height: height)
        statusLayer?.frame = CGRect(x: (bounds.width - width) / 2 + 12, y: y + 8,
                                   width: max(0, width - 24), height: height - 16)
    }

    private func dismissStatus(after delay: Double, run: UUID) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.isCurrent(run) else { return }
            self.removeStatus()
        }
    }

    private func removeStatus() {
        statusLayer?.removeFromSuperlayer()
        statusBackdrop?.removeFromSuperlayer()
        statusLayer = nil
        statusBackdrop = nil
    }

    private func startHUD(run: UUID) {
        guard Preferences.showDebugHUD else { return }
        let hud = CATextLayer()
        hud.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        hud.fontSize = 11
        hud.contentsScale = backingScale
        hud.foregroundColor = CGColor.white
        hud.backgroundColor = CGColor(gray: 0, alpha: 0.8)
        hud.frame = CGRect(x: 8, y: 8, width: 420, height: 50)
        layer?.addSublayer(hud)
        hudLayer = hud
        hudTask = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.updateHUD(hud, run: run) == true else { return }
                do { try await Task.sleep(nanoseconds: 5 * 1_000_000_000) } catch { return }
            }
        }
    }

    private func updateHUD(_ hud: CATextLayer, run: UUID) async -> Bool {
        guard isCurrent(run) else { return false }
        let stats = await imagePool?.stats()
        let registry = await ReservationRegistry.shared.count
        guard isCurrent(run) else { return false }
        hud.string = "Montage · display \(instanceNumber) · registry \(registry)\nPool \(stats?.poolDepth ?? 0)/\(stats?.poolCapacity ?? 0) · visible \(gridManager?.occupiedCellCount ?? 0)"
        return true
    }

    deinit {
        runTask?.cancel()
        geometryTask?.cancel()
        statusTask?.cancel()
        hudTask?.cancel()
        let pool = imagePool
        let grid = gridManager
        if let pool { Task { await pool.stop() } }
        if let grid { Task { @MainActor in grid.stopRotation(); grid.rootLayer.removeFromSuperlayer() } }
        InstanceTracker.shared.setActive(false, instance: instanceNumber)
    }
}

extension Notification.Name {
    static let montageConfigChanged = Notification.Name("MontageConfigChanged")
}

/// NotificationCenter supports removal from any thread. Immutable ownership of
/// its opaque token permits cleanup even from a nonisolated view deinitializer.
private final class NotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol
    init(center: NotificationCenter, name: Notification.Name,
         handler: @Sendable @escaping (Notification) -> Void) {
        self.center = center
        self.token = center.addObserver(forName: name, object: nil, queue: .main, using: handler)
    }
    deinit { center.removeObserver(token) }
}
