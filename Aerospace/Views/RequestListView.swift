//
//  RequestListView.swift
//  Aerospace
//
//  The saved-request sidebar for the API tester: selection, new, duplicate,
//  and delete.
//

import SwiftUI

struct RequestListView: View {
    @EnvironmentObject private var store: APITesterStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .frame(minWidth: 210)
    }

    private var header: some View {
        HStack {
            Text("Requests").font(.headline)
            Spacer()
            Button { store.newRequest() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New request")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var list: some View {
        if store.requests.isEmpty {
            ContentUnavailableView("No Saved Requests",
                                   systemImage: "tray",
                                   description: Text("Tap + to create one."))
        } else {
            List(selection: $store.selectedID) {
                ForEach(store.requests) { request in
                    row(request).tag(request.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func row(_ request: SavedRequest) -> some View {
        HStack(spacing: 8) {
            Text(request.method.rawValue)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(methodColor(request.method))
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.name.isEmpty ? "Untitled" : request.name)
                    .lineLimit(1)
                if !request.urlString.isEmpty {
                    Text(request.urlString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contextMenu {
            Button("Duplicate") { store.duplicate(id: request.id) }
            Button("Delete", role: .destructive) { store.delete(id: request.id) }
        }
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
    RequestListView()
        .environmentObject(APITesterStore())
        .frame(width: 240, height: 400)
}
