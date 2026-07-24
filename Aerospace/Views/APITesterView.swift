//
//  APITesterView.swift
//  Aerospace
//
//  The API-tester tool layout: a saved-request list beside a vertically split
//  editor / response pane. Uses HSplitView/VSplitView (not NavigationSplitView)
//  to compose cleanly inside the top-level tool navigator's detail column.
//

import SwiftUI

struct APITesterView: View {
    @EnvironmentObject private var store: APITesterStore

    var body: some View {
        HSplitView {
            RequestListView()
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 340)

            VStack(spacing: 0) {
                TabBarView()
                Divider()
                VSplitView {
                    RequestEditorView()
                        .frame(minWidth: 420, minHeight: 220)
                    ResponseView(response: store.lastResponse, isSending: store.isSending)
                        .frame(minWidth: 420, minHeight: 180)
                }
            }
        }
        .navigationTitle("API Tester")
    }
}

#Preview {
    APITesterView()
        .environmentObject(APITesterStore())
        .frame(width: 1000, height: 640)
}
