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

    init(frame: CGRect, rows: Int, columns: Int, rotationInterval: TimeInterval, showTitleReveal: Bool = true, titleDisplayDuration: TimeInterval = 2.0, backingScale: CGFloat = 2.0) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.rotationInterval = rotationInterval
        self.backingScale = backingScale

        // The reveal phase must fit within the rotation period alongside the
        // crossfade. If there is no room, disable the reveal rather than forcing
        // a duration that overruns the interval and causes overlapping
        // transitions.
        let availableForReveal = rotationInterval - crossfadeDuration
        if showTitleReveal && availableForReveal > 0.3 {
            self.showTitleReveal = true
            self.titleDisplayDuration = min(titleDisplayDuration, availableForReveal)
        } else {
            self.showTitleReveal = false
            self.titleDisplayDuration = 0
        }

        rootLayer.frame = frame
        rootLayer.backgroundColor = CGColor.black

        buildGrid(frame: frame)
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

    func startRotation(imagePool: ImagePool) {
        self.imagePool = imagePool

        // Fill all cells at once (hidden behind fade-in overlay) — no title reveal on initial fill
        for i in 0..<cells.count {
            rotateCellImmediate(at: i)
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

        let now = Date()

        // Weight = base randomness + staleness bonus (squared)
        // The base of 1.0 ensures true randomness even when all cells are equally fresh.
        // The staleness term ensures neglected cells get picked more often over time.
        var weights: [Double] = []
        for i in 0..<cells.count {
            let elapsed = lastUpdateTime[i].map { now.timeIntervalSince($0) } ?? rotationInterval
            let staleness = elapsed / rotationInterval  // normalize to ~1.0
            weights.append(1.0 + staleness * staleness)
        }

        let totalWeight = weights.reduce(0, +)

        // Weighted random pick
        var roll = Double.random(in: 0..<totalWeight)
        var chosen = 0
        for i in 0..<weights.count {
            roll -= weights[i]
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

    /// Rotate a cell, optionally showing the current title before crossfading to new image.
    private func rotateCell(at index: Int) {
        guard let pool = imagePool, index < cells.count else { return }
        let cell = cells[index]

        Task { [weak self] in
            if let newItem = await pool.takeImage() {
                await MainActor.run {
                    guard let self = self else { return }
                    self.lastUpdateTime[index] = Date()
                    if self.showTitleReveal {
                        self.revealThenRotate(cell: cell, index: index, newItem: newItem)
                    } else {
                        let outgoingPath = self.cellMetadata[index]?.artPath
                        cell.displayImage(newItem.image, transitionDuration: self.crossfadeDuration)
                        self.cellMetadata[index] = CellMetadata(artPath: newItem.artPath, title: newItem.title, year: newItem.year)
                        self.scheduleRelease(of: outgoingPath, afterDelay: self.crossfadeDuration)
                    }
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
            cell.displayImage(newItem.image, transitionDuration: self.crossfadeDuration)
            self.cellMetadata[index] = CellMetadata(artPath: newItem.artPath, title: newItem.title, year: newItem.year)
            // Outgoing image remains partly visible through the crossfade — keep its path
            // reserved until the crossfade completes to prevent another cell from picking it.
            self.scheduleRelease(of: outgoing?.artPath, afterDelay: self.crossfadeDuration)
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
