//
//  StatisticsView.swift
//  Aerospace
//
//  The Statistics tab: overview tiles plus Swift Charts for activity over
//  time, category distribution, and level breakdown.
//

import SwiftUI
import Charts

struct StatisticsView: View {
    @EnvironmentObject private var store: LogStore

    private var stats: LogStatistics { store.statistics }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryTiles
                activityChart
                HStack(alignment: .top, spacing: 20) {
                    categoryChart
                    levelChart
                }
                topSubCategories
            }
            .padding(20)
        }
        .navigationTitle("Statistics")
    }

    // MARK: - Summary

    private var summaryTiles: some View {
        HStack(spacing: 14) {
            StatTile(title: "Total Logs", value: "\(stats.total)",
                     systemImage: "tray.full", tint: .blue)
            StatTile(title: "Errors", value: "\(stats.errorCount)",
                     systemImage: "xmark.octagon", tint: .red)
            StatTile(title: "Categories", value: "\(stats.byCategory.count)",
                     systemImage: "folder", tint: .indigo)
            StatTile(title: "Peak / min", value: "\(stats.peak?.count ?? 0)",
                     systemImage: "chart.line.uptrend.xyaxis", tint: .green)
        }
    }

    // MARK: - Charts

    private var activityChart: some View {
        ChartCard(title: "Activity (logs per minute)") {
            if stats.perMinute.isEmpty {
                emptyChart
            } else {
                Chart(stats.perMinute) { bucket in
                    BarMark(
                        x: .value("Time", bucket.date, unit: .minute),
                        y: .value("Count", bucket.count)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                }
                .frame(height: 200)
            }
        }
    }

    private var categoryChart: some View {
        ChartCard(title: "Logs by Category") {
            if stats.byCategory.isEmpty {
                emptyChart
            } else {
                Chart(stats.byCategory.prefix(8)) { item in
                    BarMark(
                        x: .value("Count", item.count),
                        y: .value("Category", item.label)
                    )
                    .foregroundStyle(Color.blue.gradient)
                    .annotation(position: .trailing) {
                        Text("\(item.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(height: max(120, CGFloat(min(stats.byCategory.count, 8)) * 34))
            }
        }
    }

    private var levelChart: some View {
        ChartCard(title: "Logs by Level") {
            let nonEmpty = stats.byLevel.filter { $0.count > 0 }
            if nonEmpty.isEmpty {
                emptyChart
            } else {
                Chart(nonEmpty) { item in
                    SectorMark(
                        angle: .value("Count", item.count),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Level", item.label))
                    .cornerRadius(3)
                }
                .chartForegroundStyleScale(range: levelColors)
                .frame(height: 200)
            }
        }
    }

    private var levelColors: [Color] {
        stats.byLevel.filter { $0.count > 0 }.compactMap { item in
            LogLevel.allCases.first { $0.label == item.label }?.color
        }
    }

    private var topSubCategories: some View {
        ChartCard(title: "Top Subcategories") {
            if stats.bySubCategory.isEmpty {
                emptyChart
            } else {
                VStack(spacing: 0) {
                    ForEach(stats.bySubCategory.prefix(10)) { item in
                        HStack {
                            Text(item.label).font(.callout)
                            Spacer()
                            Text("\(item.count)")
                                .font(.callout.monospacedDigit().weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
        }
    }

    private var emptyChart: some View {
        Text("No data yet")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - Reusable pieces

private struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
            Text(value)
                .font(.system(.title, design: .rounded).weight(.bold))
                .contentTransition(.numericText())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
