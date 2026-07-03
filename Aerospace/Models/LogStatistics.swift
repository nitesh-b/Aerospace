//
//  LogStatistics.swift
//  Aerospace
//
//  Pure aggregation over a collection of LogEvents, used by the Statistics tab.
//

import Foundation

nonisolated struct CountedItem: Identifiable, Hashable, Sendable {
    var id: String { label }
    let label: String
    let count: Int
}

nonisolated struct TimeBucket: Identifiable, Hashable, Sendable {
    var id: Date { date }
    let date: Date
    let count: Int
}

nonisolated struct LogStatistics: Sendable {
    let total: Int
    let errorCount: Int
    let byCategory: [CountedItem]
    let bySubCategory: [CountedItem]
    let byLevel: [CountedItem]
    let perMinute: [TimeBucket]
    let peak: TimeBucket?

    static let empty = LogStatistics(
        total: 0, errorCount: 0,
        byCategory: [], bySubCategory: [], byLevel: [], perMinute: [], peak: nil
    )

    /// Map a name→count dictionary to CountedItems, ordered by descending
    /// count then ascending label.
    private static func countedItems(from counts: [String: Int]) -> [CountedItem] {
        let items = counts.map { CountedItem(label: $0.key, count: $0.value) }
        return items.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.label < rhs.label
        }
    }

    /// Compute all aggregates in a single pass over `events`.
    /// `bucketSeconds` controls the width of the time histogram (default 60s).
    static func compute(from events: [LogEvent], bucketSeconds: TimeInterval = 60) -> LogStatistics {
        guard !events.isEmpty else { return .empty }

        var categoryCounts: [String: Int] = [:]
        var subCategoryCounts: [String: Int] = [:]
        var levelCounts: [String: Int] = [:]
        var bucketCounts: [Date: Int] = [:]
        var errorCount = 0

        let width = max(1, bucketSeconds)

        for event in events {
            categoryCounts[event.category, default: 0] += 1
            subCategoryCounts["\(event.category) › \(event.subCategory)", default: 0] += 1
            levelCounts[event.level.rawValue, default: 0] += 1
            if event.level >= .error { errorCount += 1 }

            let epoch = event.timestamp.timeIntervalSince1970
            let floored = (epoch / width).rounded(.down) * width
            let bucket = Date(timeIntervalSince1970: floored)
            bucketCounts[bucket, default: 0] += 1
        }

        let byCategory = countedItems(from: categoryCounts)
        let bySubCategory = countedItems(from: subCategoryCounts)

        let byLevel = LogLevel.allCases
            .map { CountedItem(label: $0.label, count: levelCounts[$0.rawValue] ?? 0) }

        let perMinute = bucketCounts
            .map { TimeBucket(date: $0.key, count: $0.value) }
            .sorted { $0.date < $1.date }

        let peak = perMinute.max { $0.count < $1.count }

        return LogStatistics(
            total: events.count,
            errorCount: errorCount,
            byCategory: byCategory,
            bySubCategory: bySubCategory,
            byLevel: byLevel,
            perMinute: perMinute,
            peak: peak
        )
    }
}
