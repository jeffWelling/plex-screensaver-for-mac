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
    private var activeLayerIsFirst = true
    private var hasDisplayedFirstImage = false

    let row: Int
    let column: Int

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
    }

    /// Display a new image with a crossfade transition.
    func displayImage(_ image: NSImage, transitionDuration: CFTimeInterval = 1.0) {
        let inactiveLayer = activeLayerIsFirst ? layer2 : layer1
        let activeLayer = activeLayerIsFirst ? layer1 : layer2

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
        CATransaction.commit()
    }
}
