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

    // Cached-image rotation (Phase 1, before ImagePool takes over). Each cached
    // image carries its art-path key so Phase 1 can reserve through the shared
    // ReservationRegistry and never show the same artwork twice across monitors.
    private var cachedImages: [(key: String, image: NSImage)] = []
    private var cachedRotationTimer: Timer?
    /// Art-path keys this view has reserved for its cached cells (Phase 1 only),
    /// released on handoff/teardown so Phase 2 and other screens can reuse them.
    private var reservedCachedKeys: Set<String> = []
    /// The cached key currently shown in each cell, so a rotation can release the
    /// outgoing key after its crossfade.
    private var cachedCellKeys: [Int: String] = [:]
    private var isUsingCachedImages = false

    private var isRunningInApp: Bool {
        return InstanceTracker.isRunningInApp
    }

    /// Backing scale of the screen this view actually lives on (falls back to
    /// the main screen). Using the view's own screen keeps rendering crisp on
    /// mixed-DPI multi-monitor setups.
    private var backingScale: CGFloat {
        return window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
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
        textLayer.contentsScale = backingScale
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
        textLayer.contentsScale = backingScale
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
            titleDisplayDuration: Preferences.titleDisplayDuration,
            backingScale: backingScale
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

        // Capture the backing scale on the main thread for the background phase.
        let scale = backingScale

        Task {
            // Phase 1: Try to show cached images instantly
            await cache.load()
            let _ = await cache.validateConfig(serverURL: serverURL, imageSource: Preferences.imageSource)
            let cachedCount = await cache.count

            let cacheFresh = await cache.isFresh

            if cachedCount > 0 {
                let totalCells = await MainActor.run { self.gridManager?.cells.count ?? 12 }
                let images = await cache.allCachedImages(limit: totalCells * 3)

                if !images.isEmpty {
                    await self.setupCachedPhase(images: images, cacheFresh: cacheFresh, providerName: providerName)
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
            await self.startNetworkPhase(provider: provider, providerName: providerName, cache: cache, cacheFresh: cacheFresh, backingScale: scale)
        }
    }

    private func startNetworkPhase(provider: any MediaProvider, providerName: String, cache: DiskCache, cacheFresh: Bool = false, backingScale: CGFloat = 2.0) async {
        // Request images at pixel resolution (point size × backing scale) so
        // they aren't upscaled by CoreAnimation on Retina displays. Fall back to
        // sensible defaults when the grid has no size yet (e.g. pre-layout).
        let pointW = gridManager?.cellWidth ?? 0
        let pointH = gridManager?.cellHeight ?? 0
        let cellW = Int((pointW > 0 ? pointW : 480) * backingScale)
        let cellH = Int((pointH > 0 ? pointH : 270) * backingScale)
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

        if filledCount > 0 {
            await cache.markRefreshed()
        }

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

            // Hand off to ImagePool-backed rotation. Capture whether Phase 1 was
            // on-screen *before* stopping it: a cached start means the fade
            // overlay is already gone, so the pool must take over cell-by-cell
            // with crossfades rather than a visible full-grid snap (U2).
            let wasUsingCached = self.isUsingCachedImages
            OSLog.info("startImagePipeline (\(self.instanceNumber)): Phase 2 — switching to live pool (\(filledCount) images)")
            self.stopCachedRotation()

            if let gm = self.gridManager {
                gm.startRotation(imagePool: pool, staggered: wasUsingCached)
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

    /// Reserve cached art paths through the shared registry (so no artwork
    /// appears twice across monitors), assign one reserved image per cell, fade
    /// the grid in, and start cached rotation. Cells with no unreserved image
    /// available are left black rather than showing a duplicate tile (U1).
    private func setupCachedPhase(images: [(key: String, image: NSImage)], cacheFresh: Bool, providerName: String) async {
        // Shuffle so two monitors racing the same LRU-ordered cache don't even
        // attempt the same sequence (less registry contention, more variety).
        let shuffled = images.shuffled()
        let cellCount = await MainActor.run { self.gridManager?.cells.count ?? 0 }
        guard cellCount > 0 else { return }

        var assignments: [(cellIndex: Int, image: NSImage, key: String)] = []
        var reserved: Set<String> = []
        var scanIndex = 0

        for cellIndex in 0..<cellCount {
            var scanned = 0
            while scanned < shuffled.count {
                let pair = shuffled[scanIndex % shuffled.count]
                scanIndex += 1
                scanned += 1
                if reserved.contains(pair.key) { continue }
                if await ReservationRegistry.shared.reserve(artPath: pair.key) {
                    reserved.insert(pair.key)
                    assignments.append((cellIndex, pair.image, pair.key))
                    break
                }
            }
        }

        await MainActor.run {
            OSLog.info("startImagePipeline (\(self.instanceNumber)): Phase 1 — reserved \(assignments.count)/\(cellCount) cells from \(shuffled.count) cached images (fresh: \(cacheFresh))")
            self.cachedImages = shuffled
            self.reservedCachedKeys = reserved
            for a in assignments {
                if let gm = self.gridManager, a.cellIndex < gm.cells.count {
                    gm.cells[a.cellIndex].displayImage(a.image, transitionDuration: 0)
                    self.cachedCellKeys[a.cellIndex] = a.key
                }
            }
            self.isUsingCachedImages = true
            self.fadeInGrid()
            self.startCachedRotation()
            if !cacheFresh {
                self.showStatus("Connecting to \(providerName)...", position: .bottom)
            }
        }
    }

    private func startCachedRotation() {
        let interval = Preferences.rotationInterval

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.rotateCachedCell()
        }
        RunLoop.main.add(timer, forMode: .common)
        cachedRotationTimer = timer
    }

    /// Rotate one cell to a different cached image, routed through the registry
    /// so the incoming artwork is unique across all monitors and the outgoing
    /// key is released after the crossfade.
    private func rotateCachedCell() {
        Task { [weak self] in
            guard let self = self else { return }

            // Snapshot the state we need on the main thread.
            let snapshot: (cellIndex: Int, candidates: [(key: String, image: NSImage)], outgoingKey: String?, reserved: Set<String>)? = await MainActor.run {
                guard let gm = self.gridManager, !gm.cells.isEmpty, !self.cachedImages.isEmpty else { return nil }
                let cellIndex = Int.random(in: 0..<gm.cells.count)
                return (cellIndex, self.cachedImages.shuffled(), self.cachedCellKeys[cellIndex], self.reservedCachedKeys)
            }
            guard let snap = snapshot else { return }

            // Find (and reserve) the next unreserved cached image, skipping the
            // one already in this cell.
            var chosen: (key: String, image: NSImage)?
            for pair in snap.candidates {
                if pair.key == snap.outgoingKey { continue }
                if snap.reserved.contains(pair.key) { continue }
                if await ReservationRegistry.shared.reserve(artPath: pair.key) {
                    chosen = pair
                    break
                }
            }
            guard let winner = chosen else { return }  // nothing free — leave cell as-is

            await MainActor.run {
                guard self.isUsingCachedImages, let gm = self.gridManager, snap.cellIndex < gm.cells.count else {
                    // Handoff/teardown raced us — return the reservation we took.
                    Task { await ReservationRegistry.shared.release(artPath: winner.key) }
                    return
                }
                gm.cells[snap.cellIndex].displayImage(winner.image, transitionDuration: 1.0)
                self.reservedCachedKeys.insert(winner.key)
                self.cachedCellKeys[snap.cellIndex] = winner.key
                if let outgoing = snap.outgoingKey {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self = self else { return }
                        self.reservedCachedKeys.remove(outgoing)
                        Task { await ReservationRegistry.shared.release(artPath: outgoing) }
                    }
                }
            }
        }
    }

    private func stopCachedRotation() {
        cachedRotationTimer?.invalidate()
        cachedRotationTimer = nil
        cachedImages.removeAll()
        cachedCellKeys.removeAll()

        // Release every Phase-1 reservation this view still holds so Phase 2 and
        // other screens can reuse those art paths (U1 handoff/teardown release).
        let toRelease = reservedCachedKeys
        reservedCachedKeys.removeAll()
        if !toRelease.isEmpty {
            Task {
                for key in toRelease {
                    await ReservationRegistry.shared.release(artPath: key)
                }
            }
        }

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
        versionLayer?.removeFromSuperlayer()
        versionLayer = nil

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
