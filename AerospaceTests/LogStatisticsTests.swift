//
//  LogStatisticsTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class LogStatisticsTests: XCTestCase {

    private func event(_ category: String, _ sub: String, level: LogLevel = .info,
                       at offset: TimeInterval = 0) -> LogEvent {
        LogEvent(timestamp: Date(timeIntervalSince1970: 1_000_000 + offset),
                 category: category, subCategory: sub, payload: "{}", level: level)
    }

    func testEmpty() {
        let stats = LogStatistics.compute(from: [])
        XCTAssertEqual(stats.total, 0)
        XCTAssertTrue(stats.byCategory.isEmpty)
        XCTAssertNil(stats.peak)
    }

    func testTotalsAndCategories() {
        let stats = LogStatistics.compute(from: [
            event("API", "Request"), event("API", "Response"), event("Auth", "Login"),
        ])
        XCTAssertEqual(stats.total, 3)
        XCTAssertEqual(stats.byCategory.first?.label, "API")
        XCTAssertEqual(stats.byCategory.first?.count, 2)
    }

    func testErrorCount() {
        let stats = LogStatistics.compute(from: [
            event("A", "1", level: .info),
            event("A", "2", level: .error),
            event("A", "3", level: .critical),
        ])
        XCTAssertEqual(stats.errorCount, 2)
    }

    func testLevelBreakdownCoversAllLevels() {
        let stats = LogStatistics.compute(from: [event("A", "1", level: .info)])
        XCTAssertEqual(stats.byLevel.count, LogLevel.allCases.count)
        XCTAssertEqual(stats.byLevel.first { $0.label == "Info" }?.count, 1)
    }

    func testPerMinuteBucketing() {
        // Base 1_000_000 sits in the bucket [999_960, 1_000_020). Offsets
        // 0/10/19 land there; 20/79 land in the next bucket [1_000_020, …).
        let stats = LogStatistics.compute(from: [
            event("A", "1", at: 0), event("A", "2", at: 10), event("A", "3", at: 19),
            event("A", "4", at: 20), event("A", "5", at: 79),
        ], bucketSeconds: 60)
        XCTAssertEqual(stats.perMinute.count, 2)
        XCTAssertEqual(stats.perMinute[0].count, 3)
        XCTAssertEqual(stats.perMinute[1].count, 2)
        XCTAssertEqual(stats.peak?.count, 3)
    }

    func testSubCategoryLabelsIncludeCategory() {
        let stats = LogStatistics.compute(from: [event("Auth", "Login")])
        XCTAssertEqual(stats.bySubCategory.first?.label, "Auth › Login")
    }
}
