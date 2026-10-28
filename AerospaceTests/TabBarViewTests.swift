//
//  TabBarViewTests.swift
//  AerospaceTests
//
//  The tab strip's Option-Shift-Command-Left/Right shortcuts, through SwiftUI.
//

import XCTest
import SwiftUI
import AppKit
@testable import Aerospace

@MainActor
final class TabBarViewTests: XCTestCase {

    private var window: NSWindow!

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    private func makeStore(tabs names: [String]) throws -> APITesterStore {
        let sqlite = try SQLiteRequestStore(path: NSTemporaryDirectory() + "aerospace-tabbar-\(UUID().uuidString).sqlite")
        let store = APITesterStore(store: sqlite, defaults: UserDefaults(suiteName: "tabbar-\(UUID().uuidString)")!)
        for name in names {
            let request = SavedRequest(name: name, urlString: "https://example.com/\(name)")
            try store.debugUpsertRequest(request)
            store.openRequest(id: request.id, pinned: true)
        }
        return store
    }

    private func host(_ store: APITesterStore) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 40),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TabBarView().environmentObject(store))
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func press(_ arrow: Int, flags: NSEvent.ModifierFlags) -> Bool {
        let characters = String(UnicodeScalar(UInt16(arrow))!)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union(.function), timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false,
                                     keyCode: arrow == NSLeftArrowFunctionKey ? 0x7B : 0x7C)!
        // Dequeue it so it's NSApp.currentEvent, as when typed.
        NSApp.postEvent(event, atStart: true)
        let current = NSApp.nextEvent(matching: .keyDown, until: .distantPast, inMode: .default, dequeue: true)
        XCTAssertEqual(current?.modifierFlags, event.modifierFlags)
        let handled = window.performKeyEquivalent(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return handled
    }

    func testShortcutsMoveTheActiveTab() throws {
        let store = try makeStore(tabs: ["A", "B", "C"])     // C is active
        host(store)
        XCTAssertTrue(press(NSLeftArrowFunctionKey, flags: [.command, .option, .shift]))
        XCTAssertEqual(store.tabs.map(\.request.name), ["A", "C", "B"])
        _ = press(NSLeftArrowFunctionKey, flags: [.command, .option, .shift])
        XCTAssertEqual(store.tabs.map(\.request.name), ["C", "A", "B"])
        _ = press(NSRightArrowFunctionKey, flags: [.command, .option, .shift])
        XCTAssertEqual(store.tabs.map(\.request.name), ["A", "C", "B"])
    }

    func testArrowsWithoutAllModifiersDoNothing() throws {
        for flags: NSEvent.ModifierFlags in [[.command, .option], [.command, .shift], [.option, .shift], [.command], [.command, .control]] {
            let store = try makeStore(tabs: ["A", "B", "C"])
            host(store)
            _ = press(NSLeftArrowFunctionKey, flags: flags)
            XCTAssertEqual(store.tabs.map(\.request.name), ["A", "B", "C"], "flags \(flags.rawValue)")
            window.close()
        }
    }
}
