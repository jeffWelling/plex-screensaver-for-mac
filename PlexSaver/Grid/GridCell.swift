//
//  GridCell.swift
//  PlexSaver
//
//  A single grid cell with dual CALayers for crossfade transitions.
//  Based on the PictureScreenSaver dual-layer pattern.
//

import AppKit
import QuartzCore

class GridCell {
    let containerLayer = CALayer()
    private let layer1 = CALayer()
    private let layer2 = CALayer()
    private let titleBackdropLayer = CALayer()
    private let titleLayer = CATextLayer()
    private var activeLayerIsFirst = true
    private var hasDisplayedFirstImage = false
    private var currentTitle: String?

    let row: Int
    let column: Int

    /// Pill geometry — kept here so `showTitle` and `updateFrame` agree.
    private static let pillPadX: CGFloat = 8
    private static let pillPadY: CGFloat = 4
    private static let pillInsetX: CGFloat = 10  // margin from cell edge
    private static let pillInsetY: CGFloat = 10

    init(frame: CGRect, row: Int, column: Int) {
        self.row = row
        self.column = column

        containerLayer.frame = frame
        containerLayer.masksToBounds = true
        containerLayer.backgroundColor = CGColor.black

        layer1.frame = containerLayer.bounds
        layer1.contentsGravity = .resizeAspectFill
        layer1.opacity = 0

        layer2.frame = containerLayer.bounds
        layer2.contentsGravity = .resizeAspectFill
        layer2.opacity = 0

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer1.contentsScale = scale
        layer2.contentsScale = scale

        containerLayer.addSublayer(layer1)
        containerLayer.addSublayer(layer2)

        // Title backdrop pill — semi-transparent rounded rectangle behind the text.
        // Sized to fit the rendered text on each `showTitle` call.
        titleBackdropLayer.contentsScale = scale
        titleBackdropLayer.backgroundColor = CGColor(gray: 0, alpha: 0.6)
        titleBackdropLayer.cornerRadius = 4
        titleBackdropLayer.opacity = 0
        titleBackdropLayer.shadowColor = CGColor.black
        titleBackdropLayer.shadowOffset = CGSize(width: 0, height: -1)
        titleBackdropLayer.shadowRadius = 2
        titleBackdropLayer.shadowOpacity = 0.5
        containerLayer.addSublayer(titleBackdropLayer)

        // Title text — sits atop the pill. Drop shadow kept for extra legibility
        // in case the backdrop is ever hidden.
        let fontSize = GridCell.fontSize(for: frame)
        titleLayer.contentsScale = scale
        titleLayer.fontSize = fontSize
        titleLayer.font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        titleLayer.foregroundColor = CGColor.white
        titleLayer.alignmentMode = .left
        titleLayer.isWrapped = false
        titleLayer.truncationMode = .end
        titleLayer.opacity = 0
        containerLayer.addSublayer(titleLayer)

        layoutTitle(cellFrame: frame, text: nil)
    }

    /// Show a title overlay with a fade-in animation.
    func showTitle(_ title: String, fadeDuration: CFTimeInterval = 0.3) {
        currentTitle = title

        CATransaction.begin()
        CATransaction.setAnimationDuration(0)
        titleLayer.string = title
        layoutTitle(cellFrame: containerLayer.bounds, text: title)
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(fadeDuration)
        titleLayer.opacity = 1
        titleBackdropLayer.opacity = 1
        CATransaction.commit()
    }

    /// Display a new image with a crossfade transition.
    func displayImage(_ image: NSImage, transitionDuration: CFTimeInterval = 1.0) {
        let inactiveLayer = activeLayerIsFirst ? layer2 : layer1
        let activeLayer = activeLayerIsFirst ? layer1 : layer2

        // Hide title + backdrop instantly — they belong to the outgoing image
        CATransaction.begin()
        CATransaction.setAnimationDuration(0)
        titleLayer.opacity = 0
        titleBackdropLayer.opacity = 0
        CATransaction.commit()
        currentTitle = nil

        // Set image on inactive layer instantly (no animation)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0)
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        inactiveLayer.contents = cgImage
        CATransaction.commit()

        // Crossfade: fade out active, fade in inactive
        CATransaction.begin()
        CATransaction.setAnimationDuration(transitionDuration)

        if hasDisplayedFirstImage {
            activeLayer.opacity = 0
        }
        inactiveLayer.opacity = 1

        CATransaction.commit()

        activeLayerIsFirst = !activeLayerIsFirst
        hasDisplayedFirstImage = true
    }

    /// Update frame (e.g., on window resize).
    func updateFrame(_ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0)
        containerLayer.frame = frame
        layer1.frame = containerLayer.bounds
        layer2.frame = containerLayer.bounds

        let fontSize = GridCell.fontSize(for: frame)
        titleLayer.fontSize = fontSize
        titleLayer.font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        layoutTitle(cellFrame: containerLayer.bounds, text: currentTitle)
        CATransaction.commit()
    }

    // MARK: - Private

    private static func fontSize(for frame: CGRect) -> CGFloat {
        return max(11, min(frame.height / 12, 16))
    }

    /// Size the pill to fit `text` (or collapse it when `text` is nil) and park
    /// both title + backdrop in the bottom-left corner with symmetric padding.
    private func layoutTitle(cellFrame: CGRect, text: String?) {
        let fontSize = GridCell.fontSize(for: cellFrame)
        let textHeight = ceil(fontSize * 1.2)
        let pillHeight = textHeight + GridCell.pillPadY * 2

        let maxTextWidth = max(0, cellFrame.width - GridCell.pillInsetX * 2 - GridCell.pillPadX * 2)

        let textWidth: CGFloat
        if let text = text, !text.isEmpty {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let measured = (text as NSString).size(withAttributes: [.font: font]).width
            textWidth = min(ceil(measured), maxTextWidth)
        } else {
            textWidth = 0
        }

        let pillWidth = textWidth + GridCell.pillPadX * 2
        let originX = GridCell.pillInsetX
        let originY = GridCell.pillInsetY

        titleBackdropLayer.frame = CGRect(x: originX, y: originY, width: pillWidth, height: pillHeight)
        titleLayer.frame = CGRect(
            x: originX + GridCell.pillPadX,
            y: originY + GridCell.pillPadY,
            width: textWidth,
            height: textHeight
        )
    }
}
