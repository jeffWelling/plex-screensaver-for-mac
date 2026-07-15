//
//  GridManager.swift
//  PlexSaver
//

import AppKit
import QuartzCore
import os.log

/// What the grid remembers about the image currently (or most recently) shown
/// in a cell. `artPath` is the reservation key handed back to `ImagePool` when
/// the cell rotates away from this image.
private struct CellMetadata {
    let artPath: String
    let title: String
    let year: Int?
}

class GridManager {
    let rootLayer = CALayer()
    private(set) var cells: [GridCell] = []
    private var rotationTimer: Timer?
    private var imagePool: ImagePool?
    private let rows: Int
    private let columns: Int
    private let rotationInterval: TimeInterval
    private var lastUpdateTime: [Int: Date] = [:]
    private var showTitleReveal: Bool
    private var titleDisplayDuration: TimeInterval
    private let crossfadeDuration: TimeInterval = 1.0
    private let backingScale: CGFloat
    private var cellMetadata: [Int: CellMetadata] = [:]
    /// Cells with a rotation in flight (from the moment one is chosen until its
    /// crossfade completes). Excluded from the weighted pick so the same cell is
    /// never rotated twice concurrently — overlapping rotations would strand a
    /// reservation (leak) and desync the dual-layer crossfade. Main-thread only.
    private var transitioningCells: Set<Int> = []

    init(frame: CGRect, rows: Int, columns: Int, rotationInterval: TimeInterval, showTitleReveal: Bool = true, titleDisplayDuration: TimeInterval = 2.0, backingScale: CGFloat = 2.0) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.rotationInterval = rotationInterval
        self.backingScale = backingScale

        // The reveal phase must fit within the rotation period alongside the
        // crossfade. If there is no room, disable the reveal rather than forcing
        // a duration that overruns the interval and causes overlapping
        // transitions.
        let resolved = Self.resolveReveal(
            rotationInterval: rotationInterval,
            crossfadeDuration: crossfadeDuration,
            showTitleReveal: showTitleReveal,
            titleDisplayDuration: titleDisplayDuration
        )
        self.showTitleReveal = resolved.show
        self.titleDisplayDuration = resolved.duration

        rootLayer.frame = frame
        rootLayer.backgroundColor = CGColor.black

        buildGrid(frame: frame)
    }

    /// Resolve whether the title reveal fits within the rotation period and, if
    /// so, its clamped duration. Pure so it can be unit-tested (A1): the reveal is
    /// disabled unless there is more than 0.3s of headroom after the crossfade,
    /// and its duration never exceeds that headroom.
    static func resolveReveal(rotationInterval: TimeInterval, crossfadeDuration: TimeInterval, showTitleReveal: Bool, titleDisplayDuration: TimeInterval) -> (show: Bool, duration: TimeInterval) {
        let availableForReveal = rotationInterval - crossfadeDuration
        if showTitleReveal && availableForReveal > 0.3 {
            return (true, min(titleDisplayDuration, availableForReveal))
        } else {
            return (false, 0)
        }
    }

    /// Columns that best match `targetAspect` for a display of the given size and
    /// row count (N4 "Auto" grid mode). Keeps the caller's row count and picks
    /// the column count whose resulting cell aspect is closest to the source's
    /// (16:9 fanart, 2:3 posters). Pure and clamped to 1...20 so it is safe to
    /// unit-test and to feed straight into a grid build.
    static func autoColumns(width: CGFloat, height: CGFloat, rows: Int, targetAspect: CGFloat) -> Int {
        let rows = max(1, rows)
        guard width > 0, height > 0, targetAspect > 0 else { return 1 }
        let cellHeight = height / CGFloat(rows)
        let targetCellWidth = cellHeight * targetAspect
        guard targetCellWidth > 0 else { return 1 }
        let cols = Int((width / targetCellWidth).rounded())
        return max(1, min(cols, 20))
    }

    var cellWidth: CGFloat {
        return rootLayer.frame.width / CGFloat(columns)
    }

    var cellHeight: CGFloat {
        return rootLayer.frame.height / CGFloat(rows)
    }

    // MARK: - Grid Construction

    private func buildGrid(frame: CGRect) {
        let cellW = frame.width / CGFloat(columns)
        let cellH = frame.height / CGFloat(rows)

        for row in 0..<rows {
            for col in 0..<columns {
                let x = CGFloat(col) * cellW
                let y = CGFloat(row) * cellH
                let cellFrame = CGRect(x: x, y: y, width: cellW, height: cellH)
                let cell = GridCell(frame: cellFrame, row: row, column: col, backingScale: backingScale)
                cells.append(cell)
                rootLayer.addSublayer(cell.containerLayer)
            }
        }

        OSLog.info("GridManager: Built \(rows)x\(columns) grid (\(cells.count) cells), cell size: \(Int(cellW))x\(Int(cellH))")
    }

    // MARK: - Rotation

    /// Begin pool-backed rotation.
    ///
    /// `staggered` controls the initial fill. On a cold start the grid is hidden
    /// behind the fade-in overlay, so all cells can snap at once (`false`). On a
    /// cached-start handoff the overlay is already gone (Phase 1 faded it in), so
    /// a full-grid snap would be a visible hard cut — pass `true` to crossfade
    /// each cell to its first pool image, spread over a short window (U2).
    func startRotation(imagePool: ImagePool, staggered: Bool = false) {
        self.imagePool = imagePool

        if staggered {
            let window = min(rotationInterval, 3.0)
            let step = cells.isEmpty ? 0 : window / Double(cells.count)
            for i in 0..<cells.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(i)) { [weak self] in
                    self?.rotateCellCrossfadeInitial(at: i)
                }
            }
        } else {
            // Fill all cells at once (hidden behind fade-in overlay) — no title reveal on initial fill
            for i in 0..<cells.count {
                rotateCellImmediate(at: i)
            }
        }

        // One cell changes every rotationInterval seconds. Construct the timer
        // unscheduled and add it once in `.common` mode so it keeps firing
        // during event tracking without being double-registered.
        let timer = Timer(timeInterval: rotationInterval, repeats: true) { [weak self] _ in
            self?.rotateWeightedRandomCell()
        }
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer

        OSLog.info("GridManager: Started rotation, one cell every \(String(format: "%.0f", rotationInterval))s")
    }

    func stopRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        imagePool = nil
        OSLog.info("GridManager: Stopped rotation")
    }

    // MARK: - Weighted Random Selection

    private func rotateWeightedRandomCell() {
        guard !cells.isEmpty else { return }

        // Only consider cells that are not already mid-transition. Picking a cell
        // that is still crossfading would overlap two rotations on it, stranding
        // the outgoing reservation and desyncing the crossfade layers. If every
        // cell is transitioning (e.g. a 1x1 grid mid-rotation), skip this tick.
        let available = (0..<cells.count).filter { !transitioningCells.contains($0) }
        guard !available.isEmpty else { return }

        let now = Date()

        // Weight = base randomness + staleness bonus (squared)
        // The base of 1.0 ensures true randomness even when all cells are equally fresh.
        // The staleness term ensures neglected cells get picked more often over time.
        var weights: [Double] = []
        for i in available {
            let elapsed = lastUpdateTime[i].map { now.timeIntervalSince($0) } ?? rotationInterval
            let staleness = elapsed / rotationInterval  // normalize to ~1.0
            weights.append(1.0 + staleness * staleness)
        }

        let totalWeight = weights.reduce(0, +)

        // Weighted random pick over the available cells.
        var roll = Double.random(in: 0..<totalWeight)
        var chosen = available[0]
        for (j, i) in available.enumerated() {
            roll -= weights[j]
            if roll <= 0 {
                chosen = i
                break
            }
        }

        rotateCell(at: chosen)
    }

    // MARK: - Resize

    func updateFrame(_ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0)
        rootLayer.frame = frame
        CATransaction.commit()

        let cellW = frame.width / CGFloat(columns)
        let cellH = frame.height / CGFloat(rows)

        for cell in cells {
            let x = CGFloat(cell.column) * cellW
            let y = CGFloat(cell.row) * cellH
            cell.updateFrame(CGRect(x: x, y: y, width: cellW, height: cellH))
        }
    }

    // MARK: - Private

    /// Immediate rotation without title reveal — used for initial grid fill.
    /// No prior occupant exists, so nothing to release.
    private func rotateCellImmediate(at index: Int) {
        guard let pool = imagePool, index < cells.count else { return }
        let cell = cells[index]

        Task { [weak self] in
            if let item = await pool.takeImage() {
                await MainActor.run {
                    cell.displayImage(item.image, transitionDuration: 0)
                    self?.cellMetadata[index] = CellMetadata(artPath: item.artPath, title: item.title, year: item.year)
                    self?.lastUpdateTime[index] = Date()
                }
            }
        }
    }

    /// Initial fill for the staggered cached-start handoff: crossfade the cell to
    /// its first pool image (no title reveal). The cell's prior content is a
    /// Phase-1 cached image whose reservation is owned and released by
    /// `MontageView`, so there is nothing for the pool to release here.
    private func rotateCellCrossfadeInitial(at index: Int) {
        guard let pool = imagePool, index < cells.count else { return }
        let cell = cells[index]

        transitioningCells.insert(index)

        Task { [weak self] in
            let item = await pool.takeImage()
            await MainActor.run {
                guard let self = self else { return }
                guard let item = item else {
                    self.transitioningCells.remove(index)
                    return
                }
                cell.displayImage(item.image, transitionDuration: self.crossfadeDuration)
                self.cellMetadata[index] = CellMetadata(artPath: item.artPath, title: item.title, year: item.year)
                self.lastUpdateTime[index] = Date()
                self.scheduleTransitionEnd(index: index, afterDelay: self.crossfadeDuration)
            }
        }
    }

    /// Rotate a cell, optionally showing the current title before crossfading to new image.
    private func rotateCell(at index: Int) {
        guard let pool = imagePool, index < cells.count else { return }
        let cell = cells[index]

        // Mark in-transition before the async take so a subsequent tick's pick
        // excludes this cell. Cleared when the transition completes, or
        // immediately below if the pool had nothing to give.
        transitioningCells.insert(index)

        Task { [weak self] in
            let newItem = await pool.takeImage()
            await MainActor.run {
                guard let self = self else { return }
                guard let newItem = newItem else {
                    // Pool empty — cell keeps its current image; release the mark.
                    self.transitioningCells.remove(index)
                    return
                }
                self.lastUpdateTime[index] = Date()
                if self.showTitleReveal {
                    self.revealThenRotate(cell: cell, index: index, newItem: newItem)
                } else {
                    let outgoingPath = self.cellMetadata[index]?.artPath
                    cell.displayImage(newItem.image, transitionDuration: self.crossfadeDuration)
                    self.cellMetadata[index] = CellMetadata(artPath: newItem.artPath, title: newItem.title, year: newItem.year)
                    self.scheduleRelease(of: outgoingPath, afterDelay: self.crossfadeDuration)
                    self.scheduleTransitionEnd(index: index, afterDelay: self.crossfadeDuration)
                }
            }
        }
    }

    /// Two-phase rotation: reveal current title, then crossfade to new image.
    private func revealThenRotate(cell: GridCell, index: Int, newItem: ImageWithMetadata) {
        let outgoing = cellMetadata[index]

        // Show the outgoing image's title
        if let metadata = outgoing {
            var titleText = metadata.title
            if let year = metadata.year {
                titleText += " (\(year))"
            }
            cell.showTitle(titleText)
        }

        // After title display duration, crossfade to the new image
        DispatchQueue.main.asyncAfter(deadline: .now() + titleDisplayDuration) { [weak self] in
            guard let self = self else { return }
            // Re-read the cell's CURRENT occupant instead of the value captured at
            // entry. The transitioningCells guard should prevent overlap, but if a
            // race ever slipped a different rotation in, releasing the actual
            // on-screen path (not the stale captured one) avoids stranding the
            // interloper's reservation.
            let outgoingNow = self.cellMetadata[index]
            cell.displayImage(newItem.image, transitionDuration: self.crossfadeDuration)
            self.cellMetadata[index] = CellMetadata(artPath: newItem.artPath, title: newItem.title, year: newItem.year)
            // Outgoing image remains partly visible through the crossfade — keep its path
            // reserved until the crossfade completes to prevent another cell from picking it.
            self.scheduleRelease(of: outgoingNow?.artPath, afterDelay: self.crossfadeDuration)
            self.scheduleTransitionEnd(index: index, afterDelay: self.crossfadeDuration)
        }
    }

    /// Clear a cell's in-transition mark after its crossfade completes, so the
    /// weighted pick can select it again on a future tick.
    private func scheduleTransitionEnd(index: Int, afterDelay delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.transitioningCells.remove(index)
        }
    }

    /// Release an art path from the pool after the given delay (on the main queue).
    /// No-op if `artPath` is nil or the pool has already been torn down.
    private func scheduleRelease(of artPath: String?, afterDelay delay: TimeInterval) {
        guard let artPath = artPath else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let pool = self?.imagePool else { return }
            Task { await pool.release(artPath: artPath) }
        }
    }
}
