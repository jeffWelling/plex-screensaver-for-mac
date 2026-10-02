import AppKit
import QuartzCore

/// One display coordinator for cached and network artwork. All UI state lives
/// on the main actor; the pool owns downloads and reservation leases.
@MainActor
final class GridManager {
    let rootLayer = CALayer()
    private(set) var cells: [GridCell] = []
    var onFirstArtwork: (() -> Void)?
    private var rotationTimer: Timer?
    private var imagePool: ImagePool?
    private var rows: Int
    private var columns: Int
    private let rotationInterval: TimeInterval
    private var showTitleReveal: Bool
    private var titleDisplayDuration: TimeInterval
    private var backingScale: CGFloat
    private let crossfadeDuration: TimeInterval
    private let artworkFraming: ArtworkFraming
    private var runtimePolicy: PlaybackRuntimePolicy = .normal
    private var currentItems: [Int: ImageWithMetadata] = [:]
    private var outgoingItems: [Int: ImageWithMetadata] = [:]
    private var stagedItems: [Int: ImageWithMetadata] = [:]
    private var transitioning: Set<Int> = []
    private var rotationTasks: [Int: Task<Void, Never>] = [:]
    private var initialFillTask: Task<Void, Never>?
    private var lastUpdate: [Int: TimeInterval] = [:]
    private var generation = UUID()
    private var reportedFirstArtwork = false

    init(frame: CGRect, rows: Int, columns: Int, rotationInterval: TimeInterval,
         showTitleReveal: Bool = true, titleDisplayDuration: TimeInterval = 2,
         backingScale: CGFloat = 2, artworkFraming: ArtworkFraming = .fill, transitionDuration: TimeInterval = 1) {
        self.rows = min(10, max(1, rows))
        self.columns = min(20, max(1, columns))
        self.rotationInterval = rotationInterval.isFinite ? min(120, max(2, rotationInterval)) : 5
        self.artworkFraming = artworkFraming
        self.crossfadeDuration = transitionDuration.isFinite ? min(3, max(0.2, transitionDuration)) : 1
        self.backingScale = max(1, backingScale)
        let resolved = Self.resolveReveal(rotationInterval: self.rotationInterval,
                                          crossfadeDuration: crossfadeDuration,
                                          showTitleReveal: showTitleReveal,
                                          titleDisplayDuration: titleDisplayDuration)
        self.showTitleReveal = resolved.show
        self.titleDisplayDuration = resolved.duration
        rootLayer.frame = frame
        rootLayer.backgroundColor = CGColor.black
        buildGrid()
    }

    nonisolated static func resolveReveal(rotationInterval: TimeInterval, crossfadeDuration: TimeInterval,
                                         showTitleReveal: Bool, titleDisplayDuration: TimeInterval) -> (show: Bool, duration: TimeInterval) {
        guard rotationInterval.isFinite, crossfadeDuration.isFinite, titleDisplayDuration.isFinite else {
            return (false, 0)
        }
        let available = rotationInterval - crossfadeDuration
        guard showTitleReveal, available > 0.3, titleDisplayDuration > 0 else { return (false, 0) }
        return (true, min(titleDisplayDuration, available))
    }

    nonisolated static func autoColumns(width: CGFloat, height: CGFloat, rows: Int, targetAspect: CGFloat) -> Int {
        guard width.isFinite, height.isFinite, targetAspect.isFinite,
              width > 0, height > 0, targetAspect > 0 else { return 1 }
        let raw = width / ((height / CGFloat(min(10, max(1, rows)))) * targetAspect)
        return Int(min(20, max(1, raw.rounded())))
    }

    /// Leave a free candidate when possible so strict uniqueness still permits
    /// rotation. Divide scarce artwork fairly among active displays.
    nonisolated static func adaptiveDimensions(rows: Int, columns: Int, availableItems: Int,
                                              displayCount: Int) -> (rows: Int, columns: Int) {
        let rows = min(10, max(1, rows))
        let columns = min(20, max(1, columns))
        let share = max(1, availableItems / max(1, displayCount))
        let capacity = max(1, share - (share > 1 ? 1 : 0))
        guard capacity < rows * columns else { return (rows, columns) }
        let targetRatio = Double(columns) / Double(rows)
        var best = (rows: 1, columns: 1)
        var bestScore = Double.greatestFiniteMagnitude
        for r in 1...rows {
            for c in 1...columns where r * c <= capacity {
                let mismatch = abs(log((Double(c) / Double(r)) / targetRatio))
                let unused = Double(capacity - r * c) / Double(capacity)
                let score = mismatch + unused * 0.5
                if score < bestScore { best = (r, c); bestScore = score }
            }
        }
        return best
    }

    var cellWidth: CGFloat { rootLayer.bounds.width / CGFloat(columns) }
    var cellHeight: CGFloat { rootLayer.bounds.height / CGFloat(rows) }
    var occupiedCellCount: Int { currentItems.count }
    var reservationCount: Int { currentItems.count + outgoingItems.count + stagedItems.count }

    private func buildGrid() {
        for row in 0..<rows {
            for column in 0..<columns {
                let cell = GridCell(frame: CGRect(x: CGFloat(column) * cellWidth, y: CGFloat(row) * cellHeight,
                                                  width: cellWidth, height: cellHeight),
                                    row: row, column: column, backingScale: backingScale, artworkFraming: artworkFraming)
                cells.append(cell)
                rootLayer.addSublayer(cell.containerLayer)
            }
        }
    }

    func startRotation(imagePool: ImagePool) {
        if self.imagePool !== imagePool {
            stopRotation()
            self.imagePool = imagePool
        }
        guard !runtimePolicy.pausesPlayback else { return }
        fillEmptyCells()
        guard rotationTimer == nil else { return }
        let interval = max(rotationInterval, runtimePolicy.minimumRotationInterval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rotateWeightedRandomCell() }
        }
        timer.tolerance = interval * 0.15
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    /// One progressive fill consumes candidates as the bounded queue replenishes.
    /// A cold start may contain only one image; launching a take for every cell
    /// would otherwise leave the rest empty until individual rotation ticks.
    func fillEmptyCells() {
        guard !runtimePolicy.pausesPlayback, initialFillTask == nil, let pool = imagePool,
              cells.indices.contains(where: { currentItems[$0] == nil }) else { return }
        let run = generation
        initialFillTask = Task { [weak self] in
            var misses = 0
            var retryDelay: Double = 0.05
            while !Task.isCancelled {
                guard let self, self.generation == run,
                      let index = self.cells.indices.first(where: {
                          self.currentItems[$0] == nil && !self.transitioning.contains($0)
                      }) else { break }
                self.transitioning.insert(index)
                let incoming = await pool.takeImage()
                guard self.generation == run, !Task.isCancelled else {
                    if let incoming { await pool.release(item: incoming) }
                    break
                }
                if let incoming {
                    let displayed = await self.present(incoming, at: index, reveal: false, pool: pool, run: run)
                    if displayed {
                        misses = 0
                        retryDelay = 0.05
                        continue
                    }
                } else {
                    self.transitioning.remove(index)
                }
                // Background refill owns networking and its backoff. This wait
                // only gives it time to publish a candidate. Bound each idle
                // pass; the existing rotation timer retries if it stays empty.
                misses += 1
                guard misses < 12 else { break }
                do { try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000)) }
                catch { break }
                retryDelay = min(1, retryDelay * 2)
            }
            if let self, self.generation == run { self.initialFillTask = nil }
        }
    }

    func stopRotation() {
        generation = UUID()
        rotationTimer?.invalidate()
        rotationTimer = nil
        initialFillTask?.cancel()
        initialFillTask = nil
        for task in rotationTasks.values { task.cancel() }
        rotationTasks.removeAll()
        for cell in cells { cell.clear() }
        let held = Array(currentItems.values) + Array(outgoingItems.values) + Array(stagedItems.values)
        let pool = imagePool
        currentItems.removeAll()
        outgoingItems.removeAll()
        stagedItems.removeAll()
        transitioning.removeAll()
        lastUpdate.removeAll()
        imagePool = nil
        reportedFirstArtwork = false
        if let pool {
            Task { for item in held { await pool.release(item: item) } }
        }
    }

    func rotateWeightedRandomCell() {
        guard !runtimePolicy.pausesPlayback, imagePool != nil, initialFillTask == nil else { return }
        let available = cells.indices.filter { !transitioning.contains($0) }
        guard !available.isEmpty else { return }
        if available.contains(where: { currentItems[$0] == nil }) {
            fillEmptyCells()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let weights = available.map { max(1, now - (lastUpdate[$0] ?? now)) }
        var roll = Double.random(in: 0..<weights.reduce(0, +))
        var chosen = available[0]
        for (position, index) in available.enumerated() {
            roll -= weights[position]
            if roll <= 0 { chosen = index; break }
        }
        replaceCell(at: chosen, reveal: showTitleReveal)
    }

    private func replaceCell(at index: Int, reveal: Bool) {
        guard let pool = imagePool, cells.indices.contains(index), !transitioning.contains(index) else { return }
        let run = generation
        transitioning.insert(index)
        rotationTasks[index] = Task { [weak self] in
            guard let incoming = await pool.takeImage() else {
                if let self, self.generation == run {
                    self.transitioning.remove(index)
                    self.rotationTasks[index] = nil
                }
                return
            }
            guard let self, self.generation == run, !Task.isCancelled else {
                await pool.release(item: incoming)
                return
            }
            _ = await self.present(incoming, at: index, reveal: reveal, pool: pool, run: run)
            if self.generation == run { self.rotationTasks[index] = nil }
        }
    }

    /// Initial fill and periodic rotation share the same display and lease rules.
    private func present(_ incoming: ImageWithMetadata, at index: Int, reveal: Bool,
                         pool: ImagePool, run: UUID) async -> Bool {
        guard generation == run, !Task.isCancelled else {
            await pool.release(item: incoming)
            return false
        }
        stagedItems[index] = incoming
        let cell = cells[index]
        let outgoing = currentItems[index]
        if reveal, let outgoing {
            let suffix = outgoing.year.map { " (\($0))" } ?? ""
            cell.showTitle(outgoing.title + suffix)
            do { try await Task.sleep(nanoseconds: UInt64(titleDisplayDuration * 1_000_000_000)) }
            catch {
                if generation == run {
                    stagedItems[index] = nil
                    transitioning.remove(index)
                }
                await pool.release(item: incoming)
                return false
            }
        }
        guard generation == run, !Task.isCancelled else {
            await pool.release(item: incoming)
            return false
        }
        stagedItems[index] = nil
        currentItems[index] = incoming
        outgoingItems[index] = outgoing
        lastUpdate[index] = ProcessInfo.processInfo.systemUptime
        let didDisplay = cell.displayImage(incoming.image, transitionDuration: outgoing == nil ? 0 : crossfadeDuration) { [weak self] in
            if let self, self.generation == run {
                self.outgoingItems[index] = nil
                self.transitioning.remove(index)
            }
            if let outgoing { Task { await pool.release(item: outgoing) } }
        }
        if didDisplay {
            await pool.didDisplay(incoming)
            if !reportedFirstArtwork {
                reportedFirstArtwork = true
                onFirstArtwork?()
            }
        } else {
            currentItems[index] = outgoing
            outgoingItems[index] = nil
            transitioning.remove(index)
            await pool.release(item: incoming)
        }
        return didDisplay
    }

    func updateRuntimePolicy(_ policy: PlaybackRuntimePolicy) {
        guard runtimePolicy != policy else { return }
        runtimePolicy = policy
        rotationTimer?.invalidate()
        rotationTimer = nil
        for cell in cells { cell.updateRuntimePolicy(policy) }
        if policy.pausesPlayback {
            generation = UUID()
            initialFillTask?.cancel()
            initialFillTask = nil
            for task in rotationTasks.values { task.cancel() }
            rotationTasks.removeAll()
            for cell in cells { cell.finishTransition() }
            let noLongerVisible = Array(outgoingItems.values) + Array(stagedItems.values)
            outgoingItems.removeAll()
            stagedItems.removeAll()
            transitioning.removeAll()
            if let pool = imagePool { Task { for item in noLongerVisible { await pool.release(item: item) } } }
        } else if let pool = imagePool {
            startRotation(imagePool: pool)
        }
    }

    #if DEBUG
    var scheduledRotationInterval: TimeInterval? { rotationTimer?.timeInterval }
    #endif

    func updateFrame(_ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = frame
        CATransaction.commit()
        for cell in cells {
            cell.updateFrame(CGRect(x: CGFloat(cell.column) * cellWidth, y: CGFloat(cell.row) * cellHeight,
                                    width: cellWidth, height: cellHeight))
        }
    }

    func updateBackingScale(_ scale: CGFloat) {
        backingScale = max(1, scale)
        for cell in cells { cell.updateBackingScale(backingScale) }
    }

    func updateAccessibilityAppearance() {
        for cell in cells { cell.updateAccessibilityAppearance() }
    }
}
