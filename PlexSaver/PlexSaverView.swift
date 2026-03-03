//
//  PlexSaverView.swift
//  PlexSaver
//
//  Main ScreenSaverView subclass — integrates grid, Plex API, and image pipeline.
//

import ScreenSaver
import AppKit
import os.log

class PlexSaverView: ScreenSaverView {

    lazy var configSheetController: ConfigureSheetController = ConfigureSheetController()

    private var instanceNumber: Int
    private var isAnimationStarted = false
    private var gridManager: GridManager?
    private var imagePool: ImagePool?
    private var willStopObserver: NSObjectProtocol?
    private var configCloseObserver: NSObjectProtocol?
    private var initialFadeLayer: CALayer?
    private var statusLayer: CATextLayer?

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
            forName: .plexSaverConfigChanged,
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
        startImagePipeline()
    }

    override func stopAnimation() {
        guard isAnimationStarted else { return }

        OSLog.info("stopAnimation (\(instanceNumber))")
        super.stopAnimation()
        isAnimationStarted = false

        gridManager?.stopRotation()
        gridManager = nil

        let oldPool = imagePool
        imagePool = nil
        Task { await oldPool?.stop() }

        removeStatusLayer()
    }

    override func draw(_ rect: NSRect) {
        // Fill black — the grid layers render on top
        NSColor.black.setFill()
        NSBezierPath(rect: bounds).fill()
    }

    override func animateOneFrame() {
        // Animation is timer-driven via GridManager, nothing needed here
    }

    // MARK: - Status Overlay

    private func showStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.updateStatusLayer(message)
        }
    }

    private func updateStatusLayer(_ message: String) {
        guard let rootLayer = self.layer else { return }

        if statusLayer == nil {
            let textLayer = CATextLayer()
            textLayer.fontSize = min(bounds.width / 25, 24)
            textLayer.foregroundColor = CGColor(gray: 0.6, alpha: 1.0)
            textLayer.alignmentMode = .center
            textLayer.isWrapped = true
            textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            textLayer.frame = CGRect(
                x: bounds.width * 0.1,
                y: bounds.height * 0.4,
                width: bounds.width * 0.8,
                height: bounds.height * 0.2
            )
            rootLayer.addSublayer(textLayer)
            statusLayer = textLayer
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0)
        statusLayer?.string = message
        CATransaction.commit()
    }

    private func removeStatusLayer() {
        statusLayer?.removeFromSuperlayer()
        statusLayer = nil
    }

    private func fadeOutStatus() {
        guard let layer = statusLayer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0)
        layer.opacity = 0
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.removeStatusLayer()
        }
    }

    // MARK: - Setup

    private func setupGrid() {
        let rows = Preferences.gridRows
        let columns = Preferences.gridColumns
        let interval = Preferences.rotationInterval

        let manager = GridManager(frame: bounds, rows: rows, columns: columns, rotationInterval: interval)

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

    private func startImagePipeline() {
        let serverURL = Preferences.plexServerURL
        let token = Preferences.plexToken

        guard !serverURL.isEmpty, !token.isEmpty else {
            OSLog.info("startImagePipeline (\(instanceNumber)): no server configured")
            showStatus("No server configured\nOpen Options to sign in with Plex")
            return
        }

        showStatus("Connecting to Plex server...")

        let client = PlexClient(serverURL: serverURL, token: token)
        let cellW = Int(gridManager?.cellWidth ?? 480)
        let cellH = Int(gridManager?.cellHeight ?? 270)
        let totalCells = (gridManager?.cells.count ?? 12)
        let poolSize = totalCells * 3

        let pool = ImagePool(
            client: client,
            imageSource: Preferences.imageSource,
            cellWidth: cellW,
            cellHeight: cellH,
            poolSize: poolSize
        )
        self.imagePool = pool

        Task {
            let itemCount = await pool.loadMediaItems(libraryIds: Preferences.selectedLibraryIds)

            if itemCount == 0 {
                await MainActor.run {
                    self.showStatus("Could not load media from Plex\nCheck connection and try again")
                    OSLog.info("startImagePipeline (\(self.instanceNumber)): no media items loaded")
                }
                return
            }

            await MainActor.run {
                self.showStatus("Loading images (\(itemCount) items found)...")
            }

            let filledCount = await pool.prefill()

            await MainActor.run {
                if filledCount == 0 {
                    self.showStatus("Could not fetch images from Plex\nCheck server connection")
                    OSLog.info("startImagePipeline (\(self.instanceNumber)): prefill returned 0 images")
                    return
                }

                if let gm = self.gridManager {
                    gm.startRotation(imagePool: pool)
                    self.fadeOutStatus()

                    // Fade in after a short delay to let first images appear
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.fadeInGrid()
                    }
                }
            }
        }
    }

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

        // Tear down existing pipeline
        gridManager?.stopRotation()
        gridManager?.rootLayer.removeFromSuperlayer()
        gridManager = nil
        let oldPool = imagePool
        imagePool = nil
        Task { await oldPool?.stop() }
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
    static let plexSaverConfigChanged = Notification.Name("PlexSaverConfigChanged")
}
