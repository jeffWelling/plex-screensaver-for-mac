//
//  MontageView.swift
//  PlexSaver
//
//  Main ScreenSaverView subclass — integrates grid, media API, and image pipeline.
//  Two-phase startup: instant display from disk cache, then background network fetch.
//

import ScreenSaver
import AppKit
import os.log

class MontageView: ScreenSaverView {

    lazy var configSheetController: ConfigureSheetController = ConfigureSheetController()

    private var instanceNumber: Int
    private var isAnimationStarted = false
    private var gridManager: GridManager?
    private var imagePool: ImagePool?
    private var diskCache: DiskCache?
    private var willStopObserver: NSObjectProtocol?
    private var configCloseObserver: NSObjectProtocol?
    private var initialFadeLayer: CALayer?
    private var statusLayer: CATextLayer?
    private var statusBackdropLayer: CALayer?
    private var versionLayer: CATextLayer?

    // Cached-image rotation (Phase 1, before ImagePool takes over)
    private var cachedImages: [NSImage] = []
    private var cachedRotationTimer: Timer?
    private var cachedImageIndex = 0
    private var isUsingCachedImages = false

    private var isRunningInApp: Bool {
        return InstanceTracker.isRunningInApp
    }

    // MARK: - Init

    override init?(frame: NSRect, isPreview: Bool) {
        instanceNumber = 0

        // isPreview workaround (pre-Tahoe: frame size heuristic)
        var preview = isPreview
        if !InstanceTracker.isRunningInApp {
            if #available(macOS 26.0, *) {
                // Tahoe: use screen lock detection
                if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
                   let locked = dict["CGSSessionScreenIsLocked"] as? Bool, locked {
                    preview = false
                }
            } else {
                // Pre-Tahoe: frame > 400x300 means real screensaver
                if frame.width > 400 && frame.height > 300 {
                    preview = false
                }
            }
        }

        super.init(frame: frame, isPreview: preview)

        instanceNumber = InstanceTracker.shared.registerInstance(self)
        OSLog.info("init (\(instanceNumber)): frame=\(Int(frame.width))x\(Int(frame.height)), isPreview=\(preview)")

        self.wantsLayer = true
        self.layer?.backgroundColor = CGColor.black

        // Listen for config changes so we can restart the pipeline
        configCloseObserver = NotificationCenter.default.addObserver(
            forName: .montageConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigChanged()
        }

        // Register for willStop notification (non-app, non-preview)
        if !isRunningInApp && !preview {
            willStopObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.screensaver.willstop"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleWillStop()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        return configSheetController.window
    }

    // MARK: - Animation Lifecycle

    override func startAnimation() {
        guard !isAnimationStarted else {
            OSLog.info("startAnimation (\(instanceNumber)): already started, skipping")
            return
        }

        OSLog.info("startAnimation (\(instanceNumber))")
        super.startAnimation()
        isAnimationStarted = true

        setupGrid()
        showVersionOverlay()
        startImagePipeline()
    }

    override func stopAnimation() {
        guard isAnimationStarted else { return }

        OSLog.info("stopAnimation (\(instanceNumber))")
        super.stopAnimation()
        isAnimationStarted = false

        stopCachedRotation()
        gridManager?.stopRotation()
        gridManager = nil

        let oldPool = imagePool
        imagePool = nil
        Task { await oldPool?.stop() }

        diskCache = nil
        removeStatusLayer()
    }

    override func draw(_ rect: NSRect) {
        // Fill black — the grid layers render on top
        NSColor.black.setFill()
        NSBezierPath(rect: bounds).fill()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        gridManager?.updateFrame(bounds)
        initialFadeLayer?.frame = bounds
    }

    override func animateOneFrame() {
        // Animation is timer-driven via GridManager, nothing needed here
    }

    // MARK: - Status Overlay

    private enum StatusPosition {
        case centered   // No cached images behind — large centered text
        case bottom     // Cached images visible — small bottom pill
    }

    private func showStatus(_ message: String, position: StatusPosition = .centered) {
        DispatchQueue.main.async { [weak self] in
            self?.updateStatusLayer(message, position: position)
        }
    }

    private func updateStatusLayer(_ message: String, position: StatusPosition) {
        guard let rootLayer = self.layer else { return }

        // Remove existing status layers if position is changing
        if statusLayer != nil {
            removeStatusLayer()
        }

        let textLayer = CATextLayer()
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        textLayer.isWrapped = true

        switch position {
        case .centered:
            textLayer.fontSize = min(bounds.width / 25, 24)
            textLayer.foregroundColor = CGColor(gray: 0.6, alpha: 1.0)
            textLayer.alignmentMode = .center
            textLayer.frame = CGRect(
                x: bounds.width * 0.1,
                y: bounds.height * 0.4,
                width: bounds.width * 0.8,
                height: bounds.height * 0.2
            )
            rootLayer.addSublayer(textLayer)

        case .bottom:
            textLayer.fontSize = min(bounds.width / 50, 14)
            textLayer.foregroundColor = CGColor(gray: 0.8, alpha: 1.0)
            textLayer.alignmentMode = .center

            let textWidth = bounds.width * 0.5
            let textHeight: CGFloat = 24
            let pillPadding: CGFloat = 12
            let pillHeight = textHeight + pillPadding * 2
            let pillWidth = textWidth + pillPadding * 2
            let pillX = (bounds.width - pillWidth) / 2
            let pillY: CGFloat = 24

            // Semi-transparent backdrop pill
            let backdrop = CALayer()
            backdrop.frame = CGRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)
            backdrop.backgroundColor = CGColor(gray: 0, alpha: 0.6)
            backdrop.cornerRadius = pillHeight / 2
            rootLayer.addSublayer(backdrop)
            statusBackdropLayer = backdrop

            textLayer.frame = CGRect(
                x: pillX + pillPadding,
                y: pillY + pillPadding,
                width: textWidth,
                height: textHeight
            )
            rootLayer.addSublayer(textLayer)
        }

        statusLayer = textLayer

        CATransaction.begin()
        CATransaction.setAnimationDuration(0)
        textLayer.string = message
        CATransaction.commit()
    }

    private func removeStatusLayer() {
        statusLayer?.removeFromSuperlayer()
        statusLayer = nil
        statusBackdropLayer?.removeFromSuperlayer()
        statusBackdropLayer = nil
    }

    private func fadeOutStatus(delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, let layer = self.statusLayer else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(1.0)
            layer.opacity = 0
            self.statusBackdropLayer?.opacity = 0
            CATransaction.commit()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.removeStatusLayer()
            }
        }
    }

    // MARK: - Version Overlay

    private func showVersionOverlay() {
        guard let rootLayer = self.layer else { return }

        let bundle = Bundle(for: MontageView.self)
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        let textLayer = CATextLayer()
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        textLayer.string = "v\(version) (\(build))"
        textLayer.fontSize = 11
        textLayer.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textLayer.foregroundColor = CGColor(gray: 0.5, alpha: 0.7)
        textLayer.alignmentMode = .right
        textLayer.frame = CGRect(
            x: bounds.width - 200 - 8,
            y: 8,
            width: 200,
            height: 16
        )
        rootLayer.addSublayer(textLayer)
        versionLayer = textLayer

        // Fade out after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, let layer = self.versionLayer else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(1.0)
            layer.opacity = 0
            CATransaction.commit()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.versionLayer?.removeFromSuperlayer()
                self?.versionLayer = nil
            }
        }
    }

    // MARK: - Setup

    private func setupGrid() {
        let rows = Preferences.gridRows
        let columns = Preferences.gridColumns

        let manager = GridManager(
            frame: bounds,
            rows: rows,
            columns: columns,
            rotationInterval: Preferences.rotationInterval,
            showTitleReveal: Preferences.showTitleReveal,
            titleDisplayDuration: Preferences.titleDisplayDuration
        )

        guard let rootLayer = self.layer else {
            OSLog.info("setupGrid (\(instanceNumber)): no layer available")
            return
        }

        rootLayer.addSublayer(manager.rootLayer)

        // Add initial fade-in overlay
        let fadeLayer = CALayer()
        fadeLayer.frame = bounds
        fadeLayer.backgroundColor = CGColor.black
        fadeLayer.opacity = 1.0
        rootLayer.addSublayer(fadeLayer)
        initialFadeLayer = fadeLayer

        self.gridManager = manager
    }

    // MARK: - Two-Phase Startup

    private func startImagePipeline() {
        let providerType = Preferences.providerType

        // Build the appropriate provider based on user selection
        let provider: any MediaProvider
        let serverURL: String

        switch providerType {
        case .plex:
            let url = Preferences.plexServerURL
            let token = Preferences.plexToken
            guard !url.isEmpty, !token.isEmpty else {
                OSLog.info("startImagePipeline (\(instanceNumber)): no Plex server configured")
                showStatus("No server configured\nOpen Options to sign in with Plex", position: .centered)
                return
            }
            serverURL = url
            provider = PlexProvider(serverURL: url, token: token)

        case .jellyfin:
            let url = Preferences.jellyfinServerURL
            let token = Preferences.jellyfinAccessToken
            let userId = Preferences.jellyfinUserId
            guard !url.isEmpty, !token.isEmpty, !userId.isEmpty else {
                OSLog.info("startImagePipeline (\(instanceNumber)): no Jellyfin server configured")
                showStatus("No server configured\nOpen Options to sign in with Jellyfin", position: .centered)
                return
            }
            serverURL = url
            provider = JellyfinProvider(serverURL: url, accessToken: token, userId: userId)
        }

        let providerName = providerType.displayName

        // Reuse existing disk cache or create a new one
        let cache: DiskCache
        if let existing = self.diskCache {
            cache = existing
        } else {
            cache = DiskCache()
            self.diskCache = cache
        }

        Task {
            // Phase 1: Try to show cached images instantly
            await cache.load()
            let _ = await cache.validateConfig(serverURL: serverURL, imageSource: Preferences.imageSource)
            let cachedCount = await cache.count

            if cachedCount > 0 {
                let totalCells = gridManager?.cells.count ?? 12
                let images = await cache.allCachedImages(limit: totalCells * 3)

                if !images.isEmpty {
                    await MainActor.run {
                        OSLog.info("startImagePipeline (\(self.instanceNumber)): Phase 1 — showing \(images.count) cached images")
                        self.cachedImages = images
                        self.fillGridWithCachedImages()
                        self.fadeInGrid()
                        self.startCachedRotation()
                        self.showStatus("Connecting to \(providerName)...", position: .bottom)
                    }
                } else {
                    await MainActor.run {
                        self.showStatus("Connecting to \(providerName) server...", position: .centered)
                    }
                }
            } else {
                await MainActor.run {
                    self.showStatus("Connecting to \(providerName) server...", position: .centered)
                }
            }

            // Phase 2: Connect to media server in background
            await self.startNetworkPhase(provider: provider, providerName: providerName, cache: cache)
        }
    }

    private func startNetworkPhase(provider: any MediaProvider, providerName: String, cache: DiskCache) async {
        let cellW = Int(gridManager?.cellWidth ?? 480)
        let cellH = Int(gridManager?.cellHeight ?? 270)
        let totalCells = (gridManager?.cells.count ?? 12)
        let poolSize = totalCells * 3

        let pool = ImagePool(
            provider: provider,
            imageSource: Preferences.imageSource,
            cellWidth: cellW,
            cellHeight: cellH,
            poolSize: poolSize,
            diskCache: cache
        )

        await MainActor.run {
            self.imagePool = pool
        }

        let itemCount = await pool.loadMediaItems(libraryIds: Preferences.selectedLibraryIds)

        if itemCount == 0 {
            await MainActor.run {
                if self.isUsingCachedImages {
                    // Offline with cached images — show brief offline message
                    OSLog.info("startImagePipeline (\(self.instanceNumber)): offline, continuing with cached images")
                    self.showStatus("Offline — showing cached images", position: .bottom)
                    self.fadeOutStatus(delay: 3.0)
                } else {
                    self.showStatus("Could not load media from \(providerName)\nCheck connection and try again", position: .centered)
                    OSLog.info("startImagePipeline (\(self.instanceNumber)): no media items loaded")
                }
            }
            return
        }

        if !isUsingCachedImages {
            await MainActor.run {
                self.showStatus("Loading images (\(itemCount) items found)...", position: .centered)
            }
        }

        let filledCount = await pool.prefill()

        await MainActor.run {
            if filledCount == 0 {
                if self.isUsingCachedImages {
                    OSLog.info("startImagePipeline (\(self.instanceNumber)): prefill failed, continuing with cached images")
                    self.showStatus("Offline — showing cached images", position: .bottom)
                    self.fadeOutStatus(delay: 3.0)
                } else {
                    self.showStatus("Could not fetch images from \(providerName)\nCheck server connection", position: .centered)
                    OSLog.info("startImagePipeline (\(self.instanceNumber)): prefill returned 0 images")
                }
                return
            }

            // Hand off to ImagePool-backed rotation
            OSLog.info("startImagePipeline (\(self.instanceNumber)): Phase 2 — switching to live pool (\(filledCount) images)")
            self.stopCachedRotation()

            if let gm = self.gridManager {
                gm.startRotation(imagePool: pool)
                self.fadeOutStatus()

                if !self.isUsingCachedImages {
                    // First time showing images — fade in the grid
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.fadeInGrid()
                    }
                }
            }
        }
    }

    // MARK: - Cached Image Rotation (Phase 1)

    private func fillGridWithCachedImages() {
        guard let gm = gridManager, !cachedImages.isEmpty else { return }

        for (i, cell) in gm.cells.enumerated() {
            let image = cachedImages[i % cachedImages.count]
            cell.displayImage(image, transitionDuration: 0)
        }
        isUsingCachedImages = true
    }

    private func startCachedRotation() {
        let interval = Preferences.rotationInterval
        cachedImageIndex = 0

        cachedRotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.rotateCachedCell()
        }
        if let timer = cachedRotationTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func rotateCachedCell() {
        guard let gm = gridManager, !cachedImages.isEmpty else { return }
        let cellIndex = Int.random(in: 0..<gm.cells.count)
        let image = cachedImages[cachedImageIndex % cachedImages.count]
        cachedImageIndex += 1
        gm.cells[cellIndex].displayImage(image, transitionDuration: 1.0)
    }

    private func stopCachedRotation() {
        cachedRotationTimer?.invalidate()
        cachedRotationTimer = nil
        cachedImages.removeAll()
        isUsingCachedImages = false
    }

    // MARK: - Grid Fade

    private func fadeInGrid() {
        guard let fadeLayer = initialFadeLayer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.5)
        fadeLayer.opacity = 0
        CATransaction.commit()

        // Remove the fade layer after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.initialFadeLayer?.removeFromSuperlayer()
            self?.initialFadeLayer = nil
        }
    }

    // MARK: - Config Reload

    private func handleConfigChanged() {
        OSLog.info("handleConfigChanged (\(instanceNumber)): reloading pipeline")

        // Tear down existing pipeline but keep disk cache
        stopCachedRotation()
        gridManager?.stopRotation()
        gridManager?.rootLayer.removeFromSuperlayer()
        gridManager = nil
        let oldPool = imagePool
        imagePool = nil
        Task { await oldPool?.stop() }
        // diskCache is intentionally preserved across config changes
        initialFadeLayer?.removeFromSuperlayer()
        initialFadeLayer = nil
        removeStatusLayer()

        // Rebuild with new settings
        if isAnimationStarted {
            setupGrid()
            startImagePipeline()
        }
    }

    // MARK: - Lifecycle

    private func handleWillStop() {
        OSLog.info("handleWillStop (\(instanceNumber)): scheduling exit")
        stopAnimation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            exit(0)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            OSLog.info("viewDidMoveToWindow (\(instanceNumber)): \(window.screen?.localizedName ?? "unknown")")
        }
    }

    deinit {
        stopCachedRotation()
        gridManager?.stopRotation()
        if let observer = willStopObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = configCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        OSLog.info("deinit (\(instanceNumber))")
    }
}

// MARK: - Notification

extension Notification.Name {
    static let montageConfigChanged = Notification.Name("MontageConfigChanged")
}
