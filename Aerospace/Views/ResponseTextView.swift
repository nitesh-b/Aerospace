//
//  ResponseTextView.swift
//  Aerospace
//
//  AppKit-backed response body: read-only, selectable, monospaced text with
//  clickable links (Cmd+click opens a new GET tab) and a native find bar
//  (shown on demand via showFindBarSignal, bound to Cmd+S in ResponseView).
//

import SwiftUI
import AppKit

struct ResponseTextView: NSViewRepresentable {
    let text: String
    let isJSON: Bool
    var onOpenLink: (URL) -> Void
    @Binding var showFindBarSignal: Bool

    func makeCoordinator() -> Coordinator { Coordinator(onOpenLink: onOpenLink) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
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
        weak var textView: NSTextView?
        var renderedText: String?
        var renderedJSON: Bool?

        init(onOpenLink: @escaping (URL) -> Void) { self.onOpenLink = onOpenLink }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard NSEvent.modifierFlags.contains(.command) else { return false } // only Cmd+click acts
            let url: URL?
            if let u = link as? URL { url = u }
            else if let s = link as? String { url = URL(string: s) }
            else { url = nil }
            if let url { onOpenLink(url) }
            return true   // we handled it; don't let AppKit open it in a browser
        }
    }
}
