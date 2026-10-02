import XCTest
import AppKit
@testable import MontageCore

final class ViewLifecycleTests: XCTestCase {
    @MainActor
    func testRepeatedStartsAndStopsDoNotAccumulateGridOrStatusLayers() throws {
        let baseline = InstanceTracker.shared.activeCount
        let view = try XCTUnwrap(MontageView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), isPreview: false))
        for _ in 0..<12 {
            view.startAnimation()
            let count = view.layer?.sublayers?.count ?? 0
            XCTAssertGreaterThan(count, 0)
            view.startAnimation()
            XCTAssertEqual(view.layer?.sublayers?.count, count)
            XCTAssertEqual(InstanceTracker.shared.activeCount, baseline + 1)
            view.stopAnimation()
            XCTAssertEqual(view.layer?.sublayers?.count ?? 0, 0)
            XCTAssertEqual(InstanceTracker.shared.activeCount, baseline)
            view.stopAnimation()
            XCTAssertEqual(InstanceTracker.shared.activeCount, baseline)
        }
    }

    @MainActor
    func testCancelledSetupDoesNotRepopulateStoppedView() async throws {
        let view = try XCTUnwrap(MontageView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), isPreview: true))
        view.startAnimation()
        view.stopAnimation()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(view.layer?.sublayers?.count ?? 0, 0)
    }

    @MainActor
    func testDisplayChangesPublishOnlyActualChangesAndAfterUnlockingTracker() {
        let tracker = InstanceTracker.shared
        let baseline = tracker.activeCount
        let instance = tracker.registerInstance()
        let added = expectation(description: "display added")
        let removed = expectation(description: "display removed")
        let token = NotificationCenter.default.addObserver(forName: .montageDisplaysChanged, object: nil, queue: nil) { _ in
            // Reading here would deadlock if publication held the tracker lock.
            if tracker.activeCount == baseline + 1 { added.fulfill() }
            else if tracker.activeCount == baseline { removed.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(token); tracker.setActive(false, instance: instance) }
        tracker.setActive(true, instance: instance)
        tracker.setActive(true, instance: instance)
        tracker.setActive(false, instance: instance)
        tracker.setActive(false, instance: instance)
        wait(for: [added, removed], timeout: 1)
        XCTAssertEqual(tracker.activeCount, baseline)
    }

    @MainActor
    func testStoppedViewCanBeReleasedWithCancelledTasksOutstanding() async throws {
        weak var observed: MontageView?
        do {
            let view = try XCTUnwrap(MontageView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), isPreview: true))
            observed = view
            view.startAnimation()
            view.stopAnimation()
        }
        for _ in 0..<1000 {
            if observed == nil { break }
            await Task.yield()
        }
        XCTAssertNil(observed)
    }
}
