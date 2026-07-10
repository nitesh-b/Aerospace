//
//  InjectorVersion.swift
//  Aerospace
//
//  Pure, dependency-free comparison of dot-separated version strings (e.g.
//  "3.2.0"), with "x" as a wildcard component (e.g. "3.x" means "any 3.y.z").
//  Used to decide whether a release's native-version range covers a given
//  client, and to validate that a release's min/max bounds are ordered.
//

import Foundation

enum InjectorVersion {

    /// Whether `reported` falls within `[min, max]` (inclusive), where `min`
    /// and `max` may use "x" as a wildcard component.
    static func isCompatible(reported: String, min: String, max: String) -> Bool {
        let count = maxComponentCount(reported, min, max)
        let r = components(reported, wildcard: 0, count: count)
        let lo = components(min, wildcard: 0, count: count)
        let hi = components(max, wildcard: Int.max, count: count)
        return !r.lexicographicallyPrecedes(lo) && !hi.lexicographicallyPrecedes(r)
    }

    /// Whether `lower <= upper`, treating "x" in `upper` as maximally
    /// permissive. Used to validate a release's min/max bounds at publish
    /// time.
    static func isOrdered(_ lower: String, lessOrEqualTo upper: String) -> Bool {
        let count = maxComponentCount(lower, upper)
        let lo = components(lower, wildcard: 0, count: count)
        let hi = components(upper, wildcard: Int.max, count: count)
        return !hi.lexicographicallyPrecedes(lo)
    }

    private static func maxComponentCount(_ versions: String...) -> Int {
        versions.map { $0.split(separator: ".").count }.max() ?? 1
    }

    /// Splits a version string into integer components, padding with
    /// `wildcard` up to `count`. Non-numeric components (including "x") map
    /// to `wildcard`.
    private static func components(_ version: String, wildcard: Int, count: Int) -> [Int] {
        var parts = version.split(separator: ".").map { part -> Int in
            part.lowercased() == "x" ? wildcard : (Int(part) ?? wildcard)
        }
        while parts.count < count { parts.append(wildcard) }
        return parts
    }
}
