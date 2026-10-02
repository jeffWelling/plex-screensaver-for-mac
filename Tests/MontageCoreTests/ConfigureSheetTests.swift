import AppKit
import XCTest
@testable import MontageCore

@MainActor final class ConfigureSheetTests: XCTestCase {
    func testRepeatedHostRequestsPreserveWindowAndContentBeforePresentation() throws {
        _ = NSApplication.shared
        var createdModels = 0
        let controller = ConfigureSheetController {
            createdModels += 1
            return ConfigurationViewModel(restoreCredentials: false)
        }
        let first = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(first.contentViewController)
        let second = try XCTUnwrap(controller.window)
        XCTAssertTrue(first === second)
        XCTAssertTrue(content === second.contentViewController,
                      "Remote hosting must not lose its content when configureSheet is queried again")
        XCTAssertEqual(createdModels, 1)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: first))
        let reopened = try XCTUnwrap(controller.window)
        XCTAssertTrue(first === reopened)
        XCTAssertFalse(content === reopened.contentViewController)
        XCTAssertEqual(createdModels, 2, "Dismissal must refresh the next presentation")
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: reopened))
    }

    func testScreenSaverCallbackReturnsStableKeyboardAccessibleSheet() throws {
        _ = NSApplication.shared
        let view = try XCTUnwrap(MontageView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), isPreview: true))
        view.configSheetController = ConfigureSheetController { ConfigurationViewModel(restoreCredentials: false) }
        XCTAssertTrue(view.hasConfigureSheet)
        let window = try XCTUnwrap(view.configureSheet)
        let content = try XCTUnwrap(window.contentViewController)
        window.styleMask = .borderless
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window === view.configureSheet)
        XCTAssertTrue(content === view.configureSheet?.contentViewController)
        view.configSheetController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }

    func testOptionsCanReceiveKeyboardFocusAfterHostRemovesWindowChrome() {
        _ = NSApplication.shared
        let window = ConfigureSheetWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.styleMask = .borderless
        XCTAssertTrue(window.canBecomeKey, "Apple's remote sheet host removes title chrome; Options must remain keyboard accessible")
        window.close()
    }
}
