//
//  InjectorReleaseListView.swift
//  Aerospace
//
//  Release history for the Injector tool: every published release, newest
//  first.
//

import SwiftUI

struct InjectorReleaseListView: View {
    @EnvironmentObject private var store: InjectorStore

    var body: some View {
        List(store.releases) { release in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(release.app) · \(release.platform) · \(release.channel) · v\(release.version)")
                    .font(.headline)
                Text("Native \(release.minNativeVersion)–\(release.maxNativeVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(release.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("Releases")
        .overlay {
            if store.releases.isEmpty {
                ContentUnavailableView("No Releases Yet", systemImage: "shippingbox",
                                       description: Text("Publish a bundle to see it here."))
            }
        }
    }
}

#Preview {
    InjectorReleaseListView().environmentObject(InjectorStore())
}
