import AppKit
import SwiftUI
import XCTest
@testable import MontageCore

@MainActor final class ConfigureSheetTests: XCTestCase {
    private func makeParentWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 800),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }
    private func cancel(_ window: NSWindow) throws {
        let host = try XCTUnwrap(window.contentViewController as? NSHostingController<ConfigurationView>)
        host.rootView.viewModel.cancel { host.rootView.onClose?() }
    }

    func testRepeatedHostRequestsPreserveWindowAndContentBeforePresentation() throws {
        _ = NSApplication.shared
        var createdModels = 0
        let controller = ConfigureSheetController {
            createdModels += 1
            return ConfigurationViewModel(restoreCredentials: false)
        }
        let first = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(first.contentViewController)
        // Remote source views can be hidden/reparented before a sheet begins.
        first.orderOut(nil)
        let second = try XCTUnwrap(controller.window)
        XCTAssertTrue(first === second)
        XCTAssertTrue(content === second.contentViewController,
                      "Remote hosting must not lose its content when configureSheet is queried again")
        XCTAssertEqual(createdModels, 1)
        try cancel(first)
    }

    func testCancelEndsActualSheetAndReopeningRestoresGeometryAndDraft() throws {
        let parent = makeParentWindow()
        defer { parent.close() }
        var models: [ConfigurationViewModel] = []
        let controller = ConfigureSheetController {
            let model = ConfigurationViewModel(restoreCredentials: false)
            models.append(model)
            return model
        }
        let first = try XCTUnwrap(controller.window)
        first.animationBehavior = .none
        let content = try XCTUnwrap(first.contentViewController)
        let savedRows = models[0].gridRows
        let preferences = NSDictionary(dictionary: Preferences.defaults.dictionaryRepresentation())
        parent.beginSheet(first)
        XCTAssertTrue(first.sheetParent === parent)
        XCTAssertTrue(first === controller.window)
        XCTAssertTrue(content === controller.window?.contentViewController)
        XCTAssertEqual(models.count, 1)
        // Reproduce the host's borderless, smaller source window.
        first.styleMask = .borderless
        first.setContentSize(NSSize(width: 560, height: 520))
        models[0].gridRows = savedRows == 9 ? 8 : 9
        try cancel(first)
        XCTAssertNil(first.sheetParent)
        XCTAssertFalse(first.isVisible)
        let reopened = try XCTUnwrap(controller.window)
        XCTAssertFalse(first === reopened)
        XCTAssertFalse(content === reopened.contentViewController)
        XCTAssertEqual(reopened.contentView?.frame.size, NSSize(width: 620, height: 720))
        XCTAssertEqual(reopened.minSize, NSSize(width: 560, height: 540))
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[1].gridRows, savedRows, "Cancel must discard the previous presentation's draft")
        XCTAssertEqual(preferences, NSDictionary(dictionary: Preferences.defaults.dictionaryRepresentation()))
        XCTAssertTrue(first.styleMask.isEmpty, "The finished remote window's style must not be reset")
        try cancel(reopened)
    }

    func testHostEndingActualSheetRefreshesNextPresentation() throws {
        let parent = makeParentWindow()
        defer { parent.close() }
        var createdModels = 0
        let controller = ConfigureSheetController {
            createdModels += 1
            return ConfigurationViewModel(restoreCredentials: false)
        }
        let first = try XCTUnwrap(controller.window)
        first.animationBehavior = .none
        parent.beginSheet(first)
        // The host can end its sheet without calling our Cancel or close action.
        parent.endSheet(first)
        first.orderOut(nil)
        XCTAssertNil(first.sheetParent)
        let reopened = try XCTUnwrap(controller.window)
        XCTAssertFalse(first === reopened)
        XCTAssertEqual(createdModels, 2)
        try cancel(reopened)
    }

    func testNativeCloseUsesCancelAndAllowsFreshPresentation() throws {
        _ = NSApplication.shared
        var createdModels = 0
        let controller = ConfigureSheetController {
            createdModels += 1
            let model = ConfigurationViewModel(restoreCredentials: false)
            model.gridRows = 9
            return model
        }
        let preferences = NSDictionary(dictionary: Preferences.defaults.dictionaryRepresentation())
        let first = try XCTUnwrap(controller.window)
        first.animationBehavior = .none
        first.makeKeyAndOrderFront(nil)
        first.performClose(nil)
        XCTAssertFalse(first.isVisible)
        let reopened = try XCTUnwrap(controller.window)
        XCTAssertFalse(first === reopened)
        XCTAssertEqual(createdModels, 2)
        XCTAssertEqual(preferences, NSDictionary(dictionary: Preferences.defaults.dictionaryRepresentation()))
        try cancel(reopened)
    }

    func testOldCloseEndAndContentActionsDoNotDismissReplacementSheet() throws {
        let parent = makeParentWindow()
        defer { parent.close() }
        var models: [ConfigurationViewModel] = []
        let controller = ConfigureSheetController {
            let model = ConfigurationViewModel(restoreCredentials: false)
            models.append(model)
            return model
        }
        let first = try XCTUnwrap(controller.window)
        first.animationBehavior = .none
        let oldHost = try XCTUnwrap(first.contentViewController as? NSHostingController<ConfigurationView>)
        parent.beginSheet(first)
        try cancel(first)
        let second = try XCTUnwrap(controller.window)
        second.animationBehavior = .none
        let content = try XCTUnwrap(second.contentViewController)
        parent.beginSheet(second)
        models[1].isPreviewing = true
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: first))
        XCTAssertTrue(controller.windowShouldClose(first))
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: parent)
        oldHost.rootView.onClose?()
        XCTAssertTrue(second.sheetParent === parent)
        XCTAssertTrue(second === controller.window)
        XCTAssertTrue(content === second.contentViewController)
        XCTAssertTrue(models[1].isPreviewing, "Stale callbacks must not cancel the replacement model")
        XCTAssertEqual(models.count, 2)
        try cancel(second)
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
        try cancel(window)
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
