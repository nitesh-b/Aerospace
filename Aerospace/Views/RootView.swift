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
    case oztamLog
    case apiTester
    case injector
    case pauseAds
    case dynamicConfig

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logger: return "Logger"
        case .oztamLog: return "Oztam Log"
        case .apiTester: return "API Tester"
        case .injector: return "Injector"
        case .pauseAds: return "Pause Ads"
        case .dynamicConfig: return "Dynamic Config"
        }
    }

    var systemImage: String {
        switch self {
        case .logger: return "doc.text.magnifyingglass"
        case .oztamLog: return "waveform.path.ecg"
        case .apiTester: return "paperplane"
        case .injector: return "shippingbox"
        case .pauseAds: return "pause.rectangle"
        case .dynamicConfig: return "slider.horizontal.3"
        }
    }

    var subtitle: String {
        switch self {
        case .logger: return "Receive & inspect logs"
        case .oztamLog: return "Tail OzTAM meter events"
        case .apiTester: return "Build & send requests"
        case .injector: return "Publish OTA bundles"
        case .pauseAds: return "Generate & host pause ads"
        case .dynamicConfig: return "Edit per-platform config"
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
            case .oztamLog:
                OztamLogToolView()
            case .apiTester:
                APITesterView()
            case .injector:
                InjectorToolView()
            case .pauseAds:
                PauseAdToolView()
            case .dynamicConfig:
                DynamicConfigToolView()
            }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(LogStore())
        .environmentObject(OztamStore())
        .environmentObject(APITesterStore())
        .environmentObject(InjectorStore())
        .environmentObject(PauseAdStore())
        .environmentObject(DynamicConfigStore())
        .frame(width: 1000, height: 640)
}
