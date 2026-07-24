//
//  RequestListView.swift
//  Aerospace
//
//  The saved-request sidebar for the API tester: a nested folder tree with
//  drag-and-drop, opening requests into tabs.
//

import SwiftUI
import UniformTypeIdentifiers

struct RequestListView: View {
    @EnvironmentObject private var store: APITesterStore
    @State private var renaming: UUID?
    @State private var renameText = ""

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
            Button { _ = store.newFolder(parentID: nil) } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless).help("New folder")
            Button { store.newRequest() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless).help("New request")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private var list: some View {
        if store.requests.isEmpty && store.folders.isEmpty {
            ContentUnavailableView("No Saved Requests", systemImage: "tray",
                                   description: Text("Tap + to create one."))
        } else {
            List {
                // Root drop target: dropping here moves items to root (nil folder).
                ForEach(childFolders(of: nil)) { folder in
                    folderNode(folder)
                }
                ForEach(rootRequests()) { request in
                    requestRow(request)
                }
            }
            .listStyle(.sidebar)
            .onDrop(of: [.text], isTargeted: nil) { providers in
                handleDrop(providers, intoFolder: nil)
            }
        }
    }

    // MARK: - Tree helpers

    private func childFolders(of parent: UUID?) -> [RequestFolder] {
        store.folders.filter { $0.parentID == parent }
            .sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) }
    }

    private func requests(in folder: UUID?) -> [SavedRequest] {
        store.requests.filter { $0.folderID == folder }
            .sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) }
    }

    private func rootRequests() -> [SavedRequest] { requests(in: nil) }

    // MARK: - Nodes

    // Recursive views can't use an opaque `some View` return (the compiler can't
    // resolve the self-referential type), so this one is type-erased.
    private func folderNode(_ folder: RequestFolder) -> AnyView {
        AnyView(
            DisclosureGroup {
                ForEach(childFolders(of: folder.id)) { folderNode($0) }
                ForEach(requests(in: folder.id)) { requestRow($0) }
            } label: {
                folderLabel(folder)
            }
        )
    }

    private func folderLabel(_ folder: RequestFolder) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            if renaming == folder.id {
                TextField("Name", text: $renameText, onCommit: {
                    store.renameFolder(id: folder.id, to: renameText)
                    renaming = nil
                })
            } else {
                Text(folder.name).lineLimit(1)
            }
        }
        .contextMenu {
            Button("New Folder") { _ = store.newFolder(parentID: folder.id) }
            Button("New Request Here") { store.newRequest(inFolder: folder.id) }
            Button("Rename") { renameText = folder.name; renaming = folder.id }
            Button("Delete", role: .destructive) { store.deleteFolder(id: folder.id) }
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleDrop(providers, intoFolder: folder.id)
        }
    }

    private func requestRow(_ request: SavedRequest) -> some View {
        HStack(spacing: 8) {
            Text(request.method.rawValue)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(methodColor(request.method))
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.name.isEmpty ? "Untitled" : request.name).lineLimit(1)
                if !request.urlString.isEmpty {
                    Text(request.urlString).font(.caption2)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.openRequest(id: request.id, pinned: true) }
        .onTapGesture(count: 1) { store.openRequest(id: request.id, pinned: false) }
        .onDrag { NSItemProvider(object: "req:\(request.id.uuidString)" as NSString) }
        .contextMenu {
            Button("Duplicate") { store.duplicate(id: request.id) }
            Button("Delete", role: .destructive) { store.delete(id: request.id) }
        }
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider], intoFolder folderID: UUID?) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? String else { return }
                DispatchQueue.main.async {
                    if string.hasPrefix("req:"),
                       let id = UUID(uuidString: String(string.dropFirst(4))) {
                        store.move(requestID: id, toFolder: folderID)
                    } else if string.hasPrefix("fld:"),
                              let id = UUID(uuidString: String(string.dropFirst(4))) {
                        store.move(folderID: id, toParent: folderID)
                    }
                }
            }
        }
        return true
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
