//
//  KeyValueEditor.swift
//  Aerospace
//
//  A reusable add/edit/delete table over a list of KeyValueItem, used for both
//  request headers and query parameters.
//

import SwiftUI

struct KeyValueEditor: View {
    @Binding var items: [KeyValueItem]
    var keyPlaceholder: String = "Key"
    var valuePlaceholder: String = "Value"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                Text("No entries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach($items) { $item in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $item.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .help(item.isEnabled ? "Enabled" : "Disabled")
                        TextField(keyPlaceholder, text: $item.key)
                            .textFieldStyle(.roundedBorder)
                        TextField(valuePlaceholder, text: $item.value)
                            .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            items.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete row")
                    }
                    .opacity(item.isEnabled ? 1 : 0.5)
                }
            }

            Button {
                items.append(KeyValueItem())
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.top, 2)
        }
    }
}

#Preview {
    struct Wrapper: View {
        @State var items = [
            KeyValueItem(key: "Content-Type", value: "application/json"),
            KeyValueItem(key: "Accept", value: "application/json", isEnabled: false),
        ]
        var body: some View { KeyValueEditor(items: $items).padding().frame(width: 460) }
    }
    return Wrapper()
}
