//
//  OztamPollDiagnostic.swift
//  Aerospace
//
//  What the last poll did, per device. Exists so that an empty event list is
//  never ambiguous: it distinguishes "never polled" from "OzTAM answered 200
//  with nothing" from "the request failed".
//

import Foundation

nonisolated struct OztamPollDiagnostic: Identifiable, Sendable {
    enum Outcome: Sendable, Equatable {
        /// OzTAM answered, with this many meter events before flattening.
        case answered(meterEvents: Int, rows: Int)
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    let deviceID: UUID
    let deviceName: String
    var outcome: Outcome
    var polledAt: Date
    /// Total event rows this device has contributed since tailing started.
    var totalRows: Int
    /// The `fromDate` the next poll will use.
    var cursor: Date
    /// The URL the last poll hit, for pasting into curl. Never contains
    /// credentials — OzTAM auth travels as a header.
    var requestURL: String?

    var id: UUID { deviceID }

    var summary: String {
        switch outcome {
        case .answered(let meterEvents, let rows):
            if meterEvents == 0 { return "200 · no events in window" }
            if rows == 0 { return "200 · \(meterEvents) meter events, no rows parsed" }
            return "200 · \(meterEvents) meter events → \(rows) rows"
        case .failed(let message):
            return message
        }
    }
}
