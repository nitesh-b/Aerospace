//
//  RootView.swift
//  Aerospace
//
//  The top-level tool navigator: a sidebar listing the app's tools and a detail
//  area showing the selected one. New tools are added as `Tool` cases.
//

import SwiftUI

enum Tool: String, CaseIterable, Identifiable, Hashable {
    case logger
    case apiTester

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logger: return "Logger"
        case .apiTester: return "API Tester"
        }
    }

    var systemImage: String {
        switch self {
        case .logger: return "doc.text.magnifyingglass"
        case .apiTester: return "paperplane"
        }
    }

    var subtitle: String {
        switch self {
        case .logger: return "Receive & inspect logs"
        case .apiTester: return "Build & send requests"
        }
    }
}

struct RootView: View {
    @State private var selectedTool: Tool = .logger

    var body: some View {
        NavigationSplitView {
            List(Tool.allCases, selection: $selectedTool) { tool in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.title)
                        Text(tool.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: tool.systemImage)
                }
                .tag(tool)
            }
            .navigationTitle("Aerospace")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            switch selectedTool {
            case .logger:
                LoggerToolView()
            case .apiTester:
                APITesterView()
            }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(LogStore())
        .environmentObject(APITesterStore())
        .frame(width: 1000, height: 640)
}
