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

    init(frame: CGRect, rows: Int, columns: Int, rotationInterval: TimeInterval) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.rotationInterval = rotationInterval

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

        // Fill all cells at once (hidden behind fade-in overlay)
        let now = Date()
        for i in 0..<cells.count {
            rotateCell(at: i)
            lastUpdateTime[i] = now
        }

        // Start the weighted random timer immediately
        let tickInterval = rotationInterval / Double(cells.count)
        rotationTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.rotateWeightedRandomCell()
        }
        if let timer = rotationTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        OSLog.info("GridManager: Started rotation with \(rotationInterval)s interval, \(String(format: "%.2f", tickInterval))s tick")
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

    private func rotateCell(at index: Int) {
        guard let pool = imagePool, index < cells.count else { return }
        let cell = cells[index]
        lastUpdateTime[index] = Date()

        Task {
            if let image = await pool.takeImage() {
                await MainActor.run {
                    cell.displayImage(image, transitionDuration: 1.0)
                }
            }
        }
    }
}
