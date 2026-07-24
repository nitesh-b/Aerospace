//
//  TabBarView.swift
//  Aerospace
//
//  Horizontal strip of open request tabs. Single-click selects; the close
//  button removes. Preview (unpinned) tabs render in italic.
//

import SwiftUI

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
        }
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
