import AppKit
import QuartzCore

/// A cell owns its image layers only while artwork is visible or crossfading.
@MainActor
final class GridCell {
    let containerLayer = CALayer()
    private let firstLayer = CALayer()
    private let secondLayer = CALayer()
    private let titleBackdrop = CALayer()
    private let titleLayer = CATextLayer()
    private var firstIsActive = true
    private var hasImage = false
    private var generation = 0
    private var currentTitle: String?
    private var maximumAnimationDuration: TimeInterval?
    let row: Int
    let column: Int

    init(frame: CGRect, row: Int, column: Int, backingScale: CGFloat = 2, artworkFraming: ArtworkFraming = .fill) {
        self.row = row
        self.column = column
        containerLayer.masksToBounds = true
        containerLayer.backgroundColor = CGColor.black
        for imageLayer in [firstLayer, secondLayer] {
            imageLayer.contentsGravity = artworkFraming == .fit ? .resizeAspect : .resizeAspectFill
            imageLayer.opacity = 0
            containerLayer.addSublayer(imageLayer)
        }
        titleBackdrop.cornerRadius = 5
        titleBackdrop.opacity = 0
        titleLayer.alignmentMode = .left
        titleLayer.truncationMode = .end
        titleLayer.opacity = 0
        containerLayer.addSublayer(titleBackdrop)
        containerLayer.addSublayer(titleLayer)
        updateFrame(frame)
        updateBackingScale(backingScale)
        updateAccessibilityAppearance()
    }

    func showTitle(_ title: String, fadeDuration: CFTimeInterval = 0.25) {
        currentTitle = title
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.string = title
        layoutTitle()
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(effectiveDuration(fadeDuration))
        titleLayer.opacity = 1
        titleBackdrop.opacity = 1
        CATransaction.commit()
    }

    @discardableResult
    func displayImage(_ image: NSImage, transitionDuration: CFTimeInterval = 1,
                      completion: (() -> Void)? = nil) -> Bool {
        guard let bitmap = PreparedArtwork.bitmap(image) else {
            return false
        }
        generation += 1
        let transitionGeneration = generation
        let incoming = firstIsActive ? secondLayer : firstLayer
        let outgoing = firstIsActive ? firstLayer : secondLayer
        currentTitle = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.opacity = 0
        titleBackdrop.opacity = 0
        incoming.contents = bitmap
        CATransaction.commit()

        let duration = hasImage ? effectiveDuration(transitionDuration) : 0
        firstIsActive.toggle()
        hasImage = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        if duration > 0 {
            CATransaction.setCompletionBlock { [weak self, weak outgoing] in
                Task { @MainActor in
                    if let self, self.generation == transitionGeneration {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        outgoing?.contents = nil
                        CATransaction.commit()
                    }
                    completion?()
                }
            }
        }
        outgoing.opacity = 0
        incoming.opacity = 1
        CATransaction.commit()
        if duration == 0 {
            // There is no animation to wait for. Clean up synchronously so an
            // unattached preview/test layer has the same ownership semantics.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            outgoing.contents = nil
            CATransaction.commit()
            completion?()
        }
        return true
    }

    /// Settle on the model-layer image when optional animation is suspended.
    func finishTransition() {
        generation += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [firstLayer, secondLayer, titleLayer, titleBackdrop] { layer.removeAllAnimations() }
        let inactive = firstIsActive ? secondLayer : firstLayer
        inactive.contents = nil
        inactive.opacity = 0
        titleLayer.opacity = 0
        titleBackdrop.opacity = 0
        CATransaction.commit()
    }

    func updateRuntimePolicy(_ policy: PlaybackRuntimePolicy) {
        maximumAnimationDuration = policy.maximumTransitionDuration
    }

    func clear() {
        generation += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for imageLayer in [firstLayer, secondLayer] {
            imageLayer.removeAllAnimations()
            imageLayer.contents = nil
            imageLayer.opacity = 0
        }
        titleLayer.removeAllAnimations()
        titleBackdrop.removeAllAnimations()
        titleLayer.opacity = 0
        titleBackdrop.opacity = 0
        titleLayer.string = nil
        CATransaction.commit()
        hasImage = false
        currentTitle = nil
    }

    func updateFrame(_ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.frame = frame
        firstLayer.frame = containerLayer.bounds
        secondLayer.frame = containerLayer.bounds
        layoutTitle()
        CATransaction.commit()
    }

    func updateBackingScale(_ scale: CGFloat) {
        let scale = max(1, scale)
        for item in [firstLayer, secondLayer, titleBackdrop, titleLayer] {
            item.contentsScale = scale
        }
    }

    func updateAccessibilityAppearance() {
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        titleBackdrop.backgroundColor = CGColor(gray: 0, alpha: opaque ? 1 : 0.72)
        titleLayer.foregroundColor = CGColor.white
    }

    private func effectiveDuration(_ proposed: CFTimeInterval) -> CFTimeInterval {
        let accessible = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? min(proposed, 0.2) : proposed
        return maximumAnimationDuration.map { min(accessible, $0) } ?? accessible
    }

    private func layoutTitle() {
        let bounds = containerLayer.bounds
        let fontSize = max(11, min(bounds.height / 12, 18))
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        titleLayer.font = font
        titleLayer.fontSize = fontSize
        let width = min(max(0, bounds.width - 36),
                        ceil(((currentTitle ?? "") as NSString).size(withAttributes: [.font: font]).width))
        let height = ceil(fontSize * 1.3)
        titleBackdrop.frame = CGRect(x: 10, y: 10, width: width + 16, height: height + 8)
        titleLayer.frame = CGRect(x: 18, y: 14, width: width, height: height)
    }
}
