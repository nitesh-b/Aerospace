//
//  ResponseTextView.swift
//  Aerospace
//
//  AppKit-backed response body: read-only, selectable, monospaced text with
//  clickable links (Cmd+click opens a new GET tab), Cmd+Shift+= to save the
//  selected JSON field as a variable, and a native find bar (shown on demand
//  via showFindBarSignal, bound to Cmd+F in ResponseView).
//

import SwiftUI
import AppKit

struct ResponseTextView: NSViewRepresentable {
    let text: String
    let isJSON: Bool
    var onOpenLink: (URL) -> Void
    var onSaveField: (JSONField) -> Void = { _ in }
    @Binding var showFindBarSignal: Bool

    func makeCoordinator() -> Coordinator { Coordinator(onOpenLink: onOpenLink, onSaveField: onSaveField) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ResponseBodyTextView.scrollableTextView()
        guard let textView = scroll.documentView as? ResponseBodyTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticLinkDetectionEnabled = false   // we set links ourselves
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        let coordinator = context.coordinator
        textView.onCommandClickLink = { [weak coordinator] url in coordinator?.onOpenLink(url) }
        textView.onSaveField = { [weak coordinator] in coordinator?.saveSelectedField() }
        scroll.hasHorizontalScroller = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                        height: CGFloat.greatestFiniteMagnitude)
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.onSaveField = onSaveField
        guard let textView = scroll.documentView as? NSTextView else { return }

        if context.coordinator.renderedText != text || context.coordinator.renderedJSON != isJSON {
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let attributed: NSAttributedString = isJSON
                ? JSONHighlighter.attributed(text, font: font, textColor: .textColor)
                : NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
            let mutable = NSMutableAttributedString(attributedString: attributed)
            addLinks(to: mutable)
            textView.textStorage?.setAttributedString(mutable)
            context.coordinator.renderedText = text
            context.coordinator.renderedJSON = isJSON
        }

        if showFindBarSignal {
            // Show the find bar and focus it.
            textView.window?.makeFirstResponder(textView)
            textView.performFindPanelAction(makeFindAction())
            DispatchQueue.main.async { self.showFindBarSignal = false }
        }
    }

    /// A menu-item stand-in whose tag = NSTextFinder.Action.showFindInterface.
    private func makeFindAction() -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        return item
    }

    private func addLinks(to string: NSMutableAttributedString) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let full = NSRange(location: 0, length: string.length)
        detector.enumerateMatches(in: string.string, options: [], range: full) { match, _, _ in
            if let match, let url = match.url {
                string.addAttribute(.link, value: url, range: match.range)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenLink: (URL) -> Void
        var onSaveField: (JSONField) -> Void
        weak var textView: NSTextView?
        var renderedText: String?
        var renderedJSON: Bool?

        init(onOpenLink: @escaping (URL) -> Void, onSaveField: @escaping (JSONField) -> Void) {
            self.onOpenLink = onOpenLink
            self.onSaveField = onSaveField
        }

        /// Saves the field the selection (or caret) is in; beeps if there isn't one.
        func saveSelectedField() {
            guard let textView, let field = JSONField.locate(in: textView.string, selection: textView.selectedRange())
            else { return NSSound.beep() }
            onSaveField(field)
        }

        /// Adds "Save “key” as Variable" for the field under the click, or the
        /// selection when the click is inside it.
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard charIndex != NSNotFound, charIndex <= (view.string as NSString).length else { return menu }
            let selection = view.selectedRange()
            let target = selection.length > 0 && NSLocationInRange(charIndex, selection)
                ? selection : NSRange(location: charIndex, length: 0)
            guard let field = JSONField.locate(in: view.string, selection: target) else { return menu }
            let item = NSMenuItem(title: "Save “\(field.key)” as Variable",
                                  action: #selector(saveField(_:)), keyEquivalent: "+")
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = self
            item.representedObject = field
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        @objc private func saveField(_ item: NSMenuItem) {
            if let field = item.representedObject as? JSONField { onSaveField(field) }
        }
    }
}

/// The response body's text view. Cmd+click on a link is handled here, before
/// AppKit's click tracking: TextKit 2 treats a Cmd-click as a selection click
/// and never reports the link to the delegate. A plain click still follows
/// the link in the browser.
final class ResponseBodyTextView: NSTextView {
    var onCommandClickLink: ((URL) -> Void)?
    var onSaveField: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let url = link(at: event) {
            onCommandClickLink?(url)
            return
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, Self.isSaveFieldShortcut(event) {
            onSaveField?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Cmd+Shift+= (i.e. Cmd+"+"), or Cmd+Shift with the keypad plus.
    static func isSaveFieldShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains([.command, .shift]), flags.isDisjoint(with: [.option, .control]) else { return false }
        return event.charactersIgnoringModifiers == "+" || event.keyCode == 0x18 || event.keyCode == 0x45
    }

    /// The link under the mouse, if any.
    func link(at event: NSEvent) -> URL? {
        guard let window, let storage = textStorage else { return nil }
        let index = characterIndex(for: window.convertPoint(toScreen: event.locationInWindow))
        guard index != NSNotFound, index < storage.length else { return nil }
        switch storage.attribute(.link, at: index, effectiveRange: nil) {
        case let url as URL: return url
        case let string as String: return URL(string: string)
        default: return nil
        }
    }
}
