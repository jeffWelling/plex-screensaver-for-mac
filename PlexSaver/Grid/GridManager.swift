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
    private var cellTimers: [Timer] = []
    private var imagePool: ImagePool?
    private let rows: Int
    private let columns: Int
    private let rotationInterval: TimeInterval

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
        let totalCells = cells.count
        let staggerDelay = rotationInterval / Double(totalCells)

        for (index, cell) in cells.enumerated() {
            let initialDelay = staggerDelay * Double(index)

            // Fire first image immediately for each cell (staggered)
            let firstTimer = Timer.scheduledTimer(withTimeInterval: initialDelay, repeats: false) { [weak self] _ in
                self?.rotateCell(cell)
            }
            RunLoop.main.add(firstTimer, forMode: .common)

            // Then set up repeating timer
            let repeatingTimer = Timer.scheduledTimer(
                withTimeInterval: rotationInterval,
                repeats: true
            ) { [weak self] _ in
                self?.rotateCell(cell)
            }
            // Offset the first fire of the repeating timer
            repeatingTimer.fireDate = Date().addingTimeInterval(initialDelay + rotationInterval)
            RunLoop.main.add(repeatingTimer, forMode: .common)

            cellTimers.append(firstTimer)
            cellTimers.append(repeatingTimer)
        }

        OSLog.info("GridManager: Started rotation with \(rotationInterval)s interval, \(String(format: "%.2f", staggerDelay))s stagger")
    }

    func stopRotation() {
        for timer in cellTimers {
            timer.invalidate()
        }
        cellTimers.removeAll()
        imagePool = nil
        OSLog.info("GridManager: Stopped rotation")
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

    private func rotateCell(_ cell: GridCell) {
        guard let pool = imagePool else { return }

        Task {
            if let image = await pool.takeImage() {
                await MainActor.run {
                    cell.displayImage(image, transitionDuration: 1.0)
                }
            }
        }
    }
}
