//
//  TabBarView.swift
//  Aerospace
//
//  Horizontal strip of open request tabs. Single-click selects; the close
//  button removes. Preview (unpinned) tabs render in italic. Tabs reorder by
//  dragging, from the context menu, or Option-Shift-Command-Left/Right.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TabBarView: View {
    @EnvironmentObject private var store: APITesterStore

    var body: some View {
        if store.tabs.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(store.tabs) { tab in
                        chip(tab)
                        Divider().frame(height: 18)
                    }
                }
            }
            .frame(height: 32)
            .background(Color(nsColor: .windowBackgroundColor))
            .background { moveShortcuts }
        }
    }

    /// Hidden buttons carrying the shortcuts that move the active tab.
    private var moveShortcuts: some View {
        ZStack {
            Button("") { moveActiveTab(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
            Button("") { moveActiveTab(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// SwiftUI matches arrow shortcuts with or without Shift; require it so
    /// Option-Command-Left/Right (switch tabs in browsers) doesn't move tabs.
    private func moveActiveTab(by offset: Int) {
        guard NSApp.currentEvent?.modifierFlags.contains(.shift) != false, let id = store.activeTabID else { return }
        withAnimation(.easeOut(duration: 0.15)) { store.moveTab(id: id, by: offset) }
    }

    private func chip(_ tab: OpenTab) -> some View {
        let isActive = tab.id == store.activeTabID
        return HStack(spacing: 6) {
            Text(tab.request.method.rawValue)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(methodColor(tab.request.method))
            Text(tab.request.name.isEmpty ? "Untitled" : tab.request.name)
                .font(.callout)
                .italic(tab.isPreview)
                .lineLimit(1)
            Button {
                store.closeTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Close tab")
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(isActive ? Color(nsColor: .selectedControlColor) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { store.selectTab(id: tab.id) }
        .onDrag { NSItemProvider(object: "tab:\(tab.id.uuidString)" as NSString) }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleDrop(providers, onto: tab)
        }
        .contextMenu { moveMenu(tab) }
    }

    @ViewBuilder
    private func moveMenu(_ tab: OpenTab) -> some View {
        let index = store.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
        let isFirst = index == 0
        let isLast = index == store.tabs.count - 1
        Button("Move Left") { move(tab, by: -1) }
            .disabled(isFirst)
        Button("Move Right") { move(tab, by: 1) }
            .disabled(isLast)
        Divider()
        Button("Move to Start") { move(tab, to: 0) }
            .disabled(isFirst)
        Button("Move to End") { move(tab, to: store.tabs.count - 1) }
            .disabled(isLast)
        Divider()
        Button("Close Tab") { store.closeTab(id: tab.id) }
    }

    /// A dragged tab takes the place of the tab it's dropped on.
    private func handleDrop(_ providers: [NSItemProvider], onto target: OpenTab) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, string.hasPrefix("tab:"),
                  let id = UUID(uuidString: String(string.dropFirst(4))) else { return }
            DispatchQueue.main.async {
                guard id != target.id, let index = store.tabs.firstIndex(where: { $0.id == target.id }) else { return }
                withAnimation(.easeOut(duration: 0.15)) { store.moveTab(id: id, to: index) }
            }
        }
        return true
    }

    private func move(_ tab: OpenTab, by offset: Int) {
        withAnimation(.easeOut(duration: 0.15)) { store.moveTab(id: tab.id, by: offset) }
    }

    private func move(_ tab: OpenTab, to index: Int) {
        withAnimation(.easeOut(duration: 0.15)) { store.moveTab(id: tab.id, to: index) }
    }

    private func methodColor(_ method: HTTPMethod) -> Color {
        switch method {
        case .get: return .green
        case .post: return .blue
        case .put, .patch: return .orange
        case .delete: return .red
        }
    }
}

#Preview {
    TabBarView()
        .environmentObject(APITesterStore())
        .frame(width: 600)
}
