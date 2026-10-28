//
//  ResponseTextViewTests.swift
//  AerospaceTests
//
//  The response body hosted the way ResponseView hosts it: Cmd+click on a
//  link, Cmd+Shift+= and the context menu for saving a field as a variable.
//

import XCTest
import SwiftUI
import AppKit
@testable import Aerospace

@MainActor
final class ResponseTextViewTests: XCTestCase {

    private var window: NSWindow!
    private var opened: [URL] = []
    private var saved: [JSONField] = []
    private let json = #"{"token": "abc", "next": "https://example.com/page/2", "n": 1}"#

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    private func host(_ text: String) throws -> ResponseBodyTextView {
        let view = ResponseTextView(text: text, isJSON: true,
                                    onOpenLink: { [unowned self] in opened.append($0) },
                                    onSaveField: { [unowned self] in saved.append($0) },
                                    showFindBarSignal: .constant(false))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let textView = try XCTUnwrap(find(in: window.contentView!))
        textView.layoutSubtreeIfNeeded()
        return textView
    }

    private func find(in view: NSView) -> ResponseBodyTextView? {
        if let match = view as? ResponseBodyTextView { return match }
        return view.subviews.lazy.compactMap(find(in:)).first
    }

    /// Window point at the middle of the character at `index` (TextKit 2).
    private func point(at index: Int, in textView: NSTextView) throws -> NSPoint {
        let layout = try XCTUnwrap(textView.textLayoutManager)
        let content = try XCTUnwrap(layout.textContentManager)
        layout.ensureLayout(for: content.documentRange)
        let start = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: index))
        let end = try XCTUnwrap(content.location(start, offsetBy: 1))
        var rect = NSRect.zero
        layout.enumerateTextSegments(in: try XCTUnwrap(NSTextRange(location: start, end: end)),
                                     type: .standard, options: []) { _, segment, _, _ in
            rect = segment
            return false
        }
        XCTAssertFalse(rect.isEmpty)
        let origin = textView.textContainerOrigin
        return textView.convert(NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y), to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: type == .leftMouseDown ? 1 : 0)!
    }

    private func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    private func index(of needle: String, in textView: NSTextView) -> Int {
        (textView.string as NSString).range(of: needle).location
    }

    // MARK: - Cmd+click

    func testCommandClickOnALinkOpensIt() throws {
        let textView = try host(json)
        let p = try point(at: index(of: "example.com", in: textView), in: textView)
        textView.mouseDown(with: mouse(.leftMouseDown, at: p, flags: .command))
        XCTAssertEqual(opened, [URL(string: "https://example.com/page/2")!])
    }

    func testCommandClickOffALinkDoesNothing() throws {
        let textView = try host(json)
        let p = try point(at: index(of: "abc", in: textView), in: textView)
        NSApp.postEvent(mouse(.leftMouseUp, at: p, flags: .command), atStart: false)   // ends AppKit's click tracking
        textView.mouseDown(with: mouse(.leftMouseDown, at: p, flags: .command))
        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: - Save field

    func testShortcutMatching() {
        XCTAssertTrue(ResponseBodyTextView.isSaveFieldShortcut(key("+", keyCode: 0x18, flags: [.command, .shift])))
        XCTAssertTrue(ResponseBodyTextView.isSaveFieldShortcut(key("+", keyCode: 0x45, flags: [.command, .shift])))
        XCTAssertTrue(ResponseBodyTextView.isSaveFieldShortcut(key("+", keyCode: 0x1B, flags: [.command, .shift])))  // "+" elsewhere on the layout
        XCTAssertFalse(ResponseBodyTextView.isSaveFieldShortcut(key("=", keyCode: 0x18, flags: [.command])))
        XCTAssertFalse(ResponseBodyTextView.isSaveFieldShortcut(key("+", keyCode: 0x18, flags: [.command, .shift, .option])))
        XCTAssertFalse(ResponseBodyTextView.isSaveFieldShortcut(key("f", keyCode: 0x03, flags: [.command, .shift])))
    }

    func testShortcutSavesTheSelectedField() throws {
        let textView = try host(json)
        window.makeFirstResponder(textView)
        textView.setSelectedRange((textView.string as NSString).range(of: "abc"))
        XCTAssertTrue(textView.performKeyEquivalent(with: key("+", keyCode: 0x18, flags: [.command, .shift])))
        XCTAssertEqual(saved, [JSONField(key: "token", value: "abc")])
    }

    func testShortcutIsIgnoredWhenTheBodyIsNotFocused() throws {
        let textView = try host(json)
        window.makeFirstResponder(nil)
        textView.setSelectedRange((textView.string as NSString).range(of: "abc"))
        XCTAssertFalse(textView.performKeyEquivalent(with: key("+", keyCode: 0x18, flags: [.command, .shift])))
        XCTAssertTrue(saved.isEmpty)
    }

    func testContextMenuOffersTheFieldUnderTheClick() throws {
        let textView = try host(json)
        let coordinator = try XCTUnwrap(textView.delegate as? ResponseTextView.Coordinator)
        let at = index(of: "abc", in: textView)
        let p = try point(at: at, in: textView)
        let menu = try XCTUnwrap(coordinator.textView(textView, menu: NSMenu(), for: mouse(.rightMouseDown, at: p, flags: []), at: at))
        XCTAssertEqual(menu.items.first?.title, "Save “token” as Variable")
        menu.performActionForItem(at: 0)
        XCTAssertEqual(saved, [JSONField(key: "token", value: "abc")])
    }

    func testContextMenuHasNoItemOutsideAField() throws {
        let textView = try host(json)
        let coordinator = try XCTUnwrap(textView.delegate as? ResponseTextView.Coordinator)
        let menu = try XCTUnwrap(coordinator.textView(textView, menu: NSMenu(), for: mouse(.rightMouseDown, at: .zero, flags: []), at: 0))
        XCTAssertTrue(menu.items.isEmpty)
    }
}
