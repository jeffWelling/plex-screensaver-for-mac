//
//  GridManager.swift
//  PlexSaver
//

import AppKit
import QuartzCore
import os.log

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
    private var cellMetadata: [Int: (title: String, year: Int?)] = [:]

    init(frame: CGRect, rows: Int, columns: Int, rotationInterval: TimeInterval, showTitleReveal: Bool = true, titleDisplayDuration: TimeInterval = 2.0) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.rotationInterval = rotationInterval
        self.showTitleReveal = showTitleReveal
        self.titleDisplayDuration = min(titleDisplayDuration, rotationInterval - 1.0)

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
                let cell = GridCell(frame: cellFrame, row: row, column: col)
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
        let now = Date()
        for i in 0..<cells.count {
            rotateCellImmediate(at: i)
            lastUpdateTime[i] = now
        }

        // One cell changes every rotationInterval seconds
        rotationTimer = Timer.scheduledTimer(withTimeInterval: rotationInterval, repeats: true) { [weak self] _ in
            self?.rotateWeightedRandomCell()
        }
        if let timer = rotationTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

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
    private func rotateCellImmediate(at index: Int) {
        guard let pool = imagePool, index < cells.count else { return }
        let cell = cells[index]
        lastUpdateTime[index] = Date()

        Task {
            if let item = await pool.takeImage() {
                await MainActor.run {
                    cell.displayImage(item.image, transitionDuration: 0)
                    self.cellMetadata[index] = (title: item.title, year: item.year)
                }
            }
        }
    }

    /// Rotate a cell, optionally showing the current title before crossfading to new image.
    private func rotateCell(at index: Int) {
        guard let pool = imagePool, index < cells.count else { return }
        let cell = cells[index]
        lastUpdateTime[index] = Date()

        Task {
            if let newItem = await pool.takeImage() {
                await MainActor.run {
                    if self.showTitleReveal {
                        self.revealThenRotate(cell: cell, index: index, newItem: newItem)
                    } else {
                        cell.displayImage(newItem.image, transitionDuration: self.crossfadeDuration)
                        self.cellMetadata[index] = (title: newItem.title, year: newItem.year)
                    }
                }
            }
        }
    }

    /// Two-phase rotation: reveal current title, then crossfade to new image.
    private func revealThenRotate(cell: GridCell, index: Int, newItem: ImageWithMetadata) {
        // Show the outgoing image's title
        if let metadata = cellMetadata[index] {
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
            self.cellMetadata[index] = (title: newItem.title, year: newItem.year)
        }
    }
}
