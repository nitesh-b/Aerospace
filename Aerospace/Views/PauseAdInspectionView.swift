//
//  PauseAdInspectionView.swift
//  Aerospace
//
//  The Checks panel: what was found in the source hand-off folder, image
//  sizes and youi swaps, and every warning/error from PauseAdInspector.
//

import SwiftUI

struct PauseAdInspectionView: View {
    @EnvironmentObject private var store: PauseAdStore

    var body: some View {
        if let inspection = store.inspection {
            Form {
                issuesSection(inspection)
                exportSection(inspection)
                imagesSection(inspection)
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Source Folder", systemImage: "folder.badge.questionmark",
                                   description: Text("Choose the designer's hand-off folder to check it."))
        }
    }

    // MARK: - Issues

    @ViewBuilder
    private func issuesSection(_ inspection: PauseAdInspection) -> some View {
        Section("Result") {
            if inspection.issues.isEmpty {
                Label("Ready to generate. No problems found.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(Array(inspection.issues.enumerated()), id: \.offset) { _, issue in
                    Label {
                        Text(issue.message).textSelection(.enabled)
                    } icon: {
                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                    }
                }
            }
        }
    }

    // MARK: - Export

    private func exportSection(_ inspection: PauseAdInspection) -> some View {
        Section("AE export") {
            found("AEP", inspection.aepFileName)
            found("Lottie", inspection.hasLottie ? inspection.derived.lottieTarget : nil)
            found("youi layout", inspection.layoutFile)
            found("youi timeline log", inspection.timelineLogFile)
            LabeledContent("Duration") {
                Text("\(inspection.derived.duration.formatted(.number.precision(.fractionLength(0...8))))s · \(durationSource(inspection.durationSource))")
                    .foregroundStyle(inspection.durationSource == .none ? .orange : .secondary)
            }
            LabeledContent("Loop", value: inspection.derived.loop ? "Yes (Loop marker)" : "No")
        }
    }

    private func found(_ title: String, _ value: String?) -> some View {
        LabeledContent(title) {
            if let value {
                Text(value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not found").foregroundStyle(.orange)
            }
        }
    }

    private func durationSource(_ source: PauseAdInspection.DurationSource) -> String {
        switch source {
        case .timelineLog: return "youi timeline Ad-In marker"
        case .lottieMarker: return "lottie Ad-In marker"
        case .none: return "default, no Ad-In marker"
        }
    }

    // MARK: - Images

    private func imagesSection(_ inspection: PauseAdInspection) -> some View {
        Section {
            LabeledContent("Lottie images (as delivered)", value: PauseAdInspector.formatBytes(inspection.lottieImageBytes))
            LabeledContent("Lottie images (shipped)") {
                Text(PauseAdInspector.formatBytes(store.applyImageSwaps ? inspection.shippedImageBytes : inspection.lottieImageBytes))
                    .foregroundStyle(sizeColor(store.applyImageSwaps ? inspection.shippedImageBytes : inspection.lottieImageBytes))
            }
            LabeledContent("youi drawables", value: PauseAdInspector.formatBytes(inspection.youiImageBytes))
            if !inspection.swaps.isEmpty {
                DisclosureGroup("\(inspection.swaps.count) youi image\(inspection.swaps.count == 1 ? "" : "s") \(store.applyImageSwaps ? "will replace" : "could replace") lottie ones") {
                    ForEach(inspection.swaps, id: \.self) { swap in
                        LabeledContent(swap.name) {
                            Text("\(PauseAdInspector.formatBytes(swap.lottieBytes)) → \(PauseAdInspector.formatBytes(swap.youiBytes))")
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
        } header: {
            Text("Images")
        } footer: {
            Text("Ideally under 3 MB; over 5 MB loads slowly on low-end TVs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sizeColor(_ bytes: Int) -> Color {
        if bytes > PauseAdInspector.maxImageBytes { return .red }
        if bytes > PauseAdInspector.warnImageBytes { return .orange }
        return .secondary
    }
}
