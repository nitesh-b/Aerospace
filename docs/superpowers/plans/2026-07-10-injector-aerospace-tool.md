# Injector — Aerospace Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third sidebar tool, "Injector," to the Aerospace macOS app: a local release registry that lets a developer import a pre-built React Native JS bundle, tag it (app/platform/channel/native-version range), publish it, and serve it over a local HTTP API — the Aerospace-side half of a CodePush-style OTA system (the RN client SDK that consumes this API is a separate, later plan).

**Architecture:** Clones Aerospace's existing per-tool pattern exactly: a new `Tool.injector` sidebar case, a `@MainActor` `InjectorStore` facade owning a raw-SQLite3 metadata store (`SQLiteInjectorReleaseStore`) and an independent `Network.framework`-based HTTP server (`HTTPInjectorServer`) on its own port, with bundle binaries kept as flat files on disk (never in SQLite). No infrastructure is shared with Logger — this mirrors how API Tester was added without touching Logger's code.

**Tech Stack:** Swift, SwiftUI, Apple `Network` framework, system `SQLite3` C library, `CryptoKit` (SHA-256) — no third-party dependencies.

## Global Constraints

- No third-party dependencies anywhere in the Aerospace app — only system frameworks (Foundation, SwiftUI, Network, SQLite3, CryptoKit).
- Bundle binaries are stored as flat files on disk; SQLite holds metadata only (no blob columns) — per spec's Data Model section.
- The HTTP API has no authentication; it trusts the local network, matching Logger's existing model — per spec's Scope section.
- Injector's HTTP server is a separate `NWListener` instance on its own port (default `57334`), independent of Logger's server — per spec's Architecture section.
- No bundler invocation, no percentage rollout, no remote hosting, no crash reporting endpoint — all explicitly out of scope for this plan, per spec's Scope section.
- New source files are created under `Aerospace/`, `AerospaceTests/` — this project uses Xcode's file-system-synchronized groups (confirmed via `project.pbxproj`), so any file placed in those directories is automatically included in its target; no `.pbxproj` editing is needed.

---

## Reference: running tests

Every test step in this plan uses:

```bash
xcodebuild test -project Aerospace.xcodeproj -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/<TestClassName>
```

A passing run ends with `** TEST SUCCEEDED **`. Before any implementation code exists, the equivalent "expected failure" is a **build failure** (Swift/Xcode's TDD red state is a compile error, e.g. `cannot find 'X' in scope`), not a runtime assertion failure — that's expected and correct at that step.

---

### Task 1: Injector version-comparison utility + release model

**Files:**
- Create: `Aerospace/Models/InjectorVersion.swift`
- Create: `Aerospace/Models/InjectorRelease.swift`
- Test: `AerospaceTests/InjectorVersionTests.swift`
- Test: `AerospaceTests/InjectorReleaseTests.swift`

**Interfaces:**
- Produces: `InjectorVersion.isCompatible(reported: String, min: String, max: String) -> Bool`, `InjectorVersion.isOrdered(_ lower: String, lessOrEqualTo upper: String) -> Bool`, `InjectorRelease` (struct: `id, app, platform, channel, version, minNativeVersion, maxNativeVersion, bundleHash, bundlePath, createdAt: Date`, all `String` except `createdAt`), `InjectorRelease.isCompatible(withNativeVersion:) -> Bool`. Every later task depends on these exact names and signatures.

- [ ] **Step 1: Write the failing tests for `InjectorVersion`**

Create `AerospaceTests/InjectorVersionTests.swift`:

```swift
//
//  InjectorVersionTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class InjectorVersionTests: XCTestCase {

    func testIsCompatibleWithinRange() {
        XCTAssertTrue(InjectorVersion.isCompatible(reported: "3.5.0", min: "3.2.0", max: "3.9.0"))
    }

    func testIsCompatibleBelowMin() {
        XCTAssertFalse(InjectorVersion.isCompatible(reported: "3.1.0", min: "3.2.0", max: "3.9.0"))
    }

    func testIsCompatibleAboveMax() {
        XCTAssertFalse(InjectorVersion.isCompatible(reported: "4.0.0", min: "3.2.0", max: "3.9.0"))
    }

    func testIsCompatibleAtExactBounds() {
        XCTAssertTrue(InjectorVersion.isCompatible(reported: "3.2.0", min: "3.2.0", max: "3.9.0"))
        XCTAssertTrue(InjectorVersion.isCompatible(reported: "3.9.0", min: "3.2.0", max: "3.9.0"))
    }

    func testIsCompatibleWithWildcardMaxAllowsAnyMinorPatch() {
        XCTAssertTrue(InjectorVersion.isCompatible(reported: "3.99.4", min: "3.0.0", max: "3.x"))
    }

    func testIsCompatibleWithWildcardMaxExcludesNextMajor() {
        XCTAssertFalse(InjectorVersion.isCompatible(reported: "4.0.0", min: "3.0.0", max: "3.x"))
    }

    func testIsOrderedTrueWhenLowerLessThanUpper() {
        XCTAssertTrue(InjectorVersion.isOrdered("3.2.0", lessOrEqualTo: "3.9.0"))
    }

    func testIsOrderedFalseWhenLowerGreaterThanUpper() {
        XCTAssertFalse(InjectorVersion.isOrdered("3.9.0", lessOrEqualTo: "3.2.0"))
    }

    func testIsOrderedTrueWhenEqual() {
        XCTAssertTrue(InjectorVersion.isOrdered("3.2.0", lessOrEqualTo: "3.2.0"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Aerospace.xcodeproj -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/InjectorVersionTests`
Expected: **BUILD FAILED**, with an error like `cannot find 'InjectorVersion' in scope`.

- [ ] **Step 3: Implement `InjectorVersion`**

Create `Aerospace/Models/InjectorVersion.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project Aerospace.xcodeproj -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/InjectorVersionTests`
Expected: `** TEST SUCCEEDED **`, all 9 test cases passed.

- [ ] **Step 5: Write the failing tests for `InjectorRelease`**

Create `AerospaceTests/InjectorReleaseTests.swift`:

```swift
//
//  InjectorReleaseTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class InjectorReleaseTests: XCTestCase {

    private func release(min: String = "1.0.0", max: String = "1.x") -> InjectorRelease {
        InjectorRelease(id: "r1", app: "myapp", platform: "ios", channel: "staging",
                        version: "1", minNativeVersion: min, maxNativeVersion: max,
                        bundleHash: "abc123", bundlePath: "/tmp/x", createdAt: Date())
    }

    func testIsCompatibleDelegatesToInjectorVersion() {
        let r = release(min: "1.0.0", max: "1.x")
        XCTAssertTrue(r.isCompatible(withNativeVersion: "1.5.0"))
        XCTAssertFalse(r.isCompatible(withNativeVersion: "2.0.0"))
    }

    func testEquatable() {
        XCTAssertEqual(release(), release())
    }
}
```

- [ ] **Step 6: Run the tests to verify they fail**

Run: `xcodebuild test -project Aerospace.xcodeproj -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/InjectorReleaseTests`
Expected: **BUILD FAILED**, `cannot find 'InjectorRelease' in scope`.

- [ ] **Step 7: Implement `InjectorRelease`**

Create `Aerospace/Models/InjectorRelease.swift`:

```swift
//
//  InjectorRelease.swift
//  Aerospace
//
//  A single published Injector release: which app/platform/channel it
//  targets, which native-app-version range it's compatible with, and where
//  its bundle file lives on disk. Persisted by SQLiteInjectorReleaseStore;
//  the bundle bytes themselves are a flat file, not stored here.
//

import Foundation

struct InjectorRelease: Identifiable, Equatable, Sendable {
    let id: String
    let app: String
    let platform: String
    let channel: String
    let version: String
    let minNativeVersion: String
    let maxNativeVersion: String
    let bundleHash: String
    let bundlePath: String
    let createdAt: Date

    func isCompatible(withNativeVersion nativeVersion: String) -> Bool {
        InjectorVersion.isCompatible(reported: nativeVersion, min: minNativeVersion, max: maxNativeVersion)
    }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `xcodebuild test -project Aerospace.xcodeproj -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/InjectorReleaseTests`
Expected: `** TEST SUCCEEDED **`, both test cases passed.

- [ ] **Step 9: Commit**

```bash
git add Aerospace/Models/InjectorVersion.swift Aerospace/Models/InjectorRelease.swift \
        AerospaceTests/InjectorVersionTests.swift AerospaceTests/InjectorReleaseTests.swift
git commit -m "Add Injector release model and native-version compatibility check"
```

---

### Task 2: SQLite release-metadata store

**Files:**
- Create: `Aerospace/Storage/SQLiteInjectorReleaseStore.swift`
- Test: `AerospaceTests/SQLiteInjectorReleaseStoreTests.swift`

**Interfaces:**
- Consumes: `InjectorRelease` (Task 1), the shared `SQLiteError` enum (defined in `Aerospace/Storage/SQLiteLogStore.swift`, internal-visibility, already reused as-is by `SQLiteRequestStore.swift` — do not redeclare it).
- Produces: `SQLiteInjectorReleaseStore(path: String) throws`, `.insert(_ release: InjectorRelease) throws`, `.fetchAll() -> [InjectorRelease]`, `.releases(app: String, platform: String, channel: String) -> [InjectorRelease]` (newest first), `.latestCompatibleRelease(app: String, platform: String, channel: String, nativeVersion: String) -> InjectorRelease?`, `.release(id: String) -> InjectorRelease?`. Task 4 depends on these exact names.

- [ ] **Step 1: Write the failing tests**

Create `AerospaceTests/SQLiteInjectorReleaseStoreTests.swift`:

```swift
//
//  SQLiteInjectorReleaseStoreTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class SQLiteInjectorReleaseStoreTests: XCTestCase {

    private func makeStore() throws -> SQLiteInjectorReleaseStore {
        let path = NSTemporaryDirectory() + "aerospace-injector-test-\(UUID().uuidString).sqlite"
        return try SQLiteInjectorReleaseStore(path: path)
    }

    private func release(id: String = UUID().uuidString, app: String = "myapp",
                        platform: String = "ios", channel: String = "staging",
                        version: String = "1", min: String = "1.0.0", max: String = "1.x",
                        createdAt: Date = Date()) -> InjectorRelease {
        InjectorRelease(id: id, app: app, platform: platform, channel: channel, version: version,
                        minNativeVersion: min, maxNativeVersion: max, bundleHash: "hash-\(id)",
                        bundlePath: "/tmp/\(id).bundle", createdAt: createdAt)
    }

    func testInsertAndFetchAll() throws {
        let store = try makeStore()
        try store.insert(release(id: "a"))
        try store.insert(release(id: "b"))
        XCTAssertEqual(store.fetchAll().count, 2)
    }

    func testFetchAllOrdersNewestFirst() throws {
        let store = try makeStore()
        try store.insert(release(id: "old", createdAt: Date(timeIntervalSince1970: 0)))
        try store.insert(release(id: "new", createdAt: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(store.fetchAll().first?.id, "new")
        XCTAssertEqual(store.fetchAll().last?.id, "old")
    }

    func testReleasesFiltersByAppPlatformChannel() throws {
        let store = try makeStore()
        try store.insert(release(id: "match", app: "myapp", platform: "ios", channel: "staging"))
        try store.insert(release(id: "other-app", app: "otherapp", platform: "ios", channel: "staging"))
        try store.insert(release(id: "other-platform", app: "myapp", platform: "android", channel: "staging"))
        try store.insert(release(id: "other-channel", app: "myapp", platform: "ios", channel: "prod"))

        let result = store.releases(app: "myapp", platform: "ios", channel: "staging")
        XCTAssertEqual(result.map(\.id), ["match"])
    }

    func testLatestCompatibleReleaseRespectsNativeVersionRange() throws {
        let store = try makeStore()
        try store.insert(release(id: "too-old", min: "1.0.0", max: "1.x",
                                 createdAt: Date(timeIntervalSince1970: 0)))
        try store.insert(release(id: "compatible", min: "2.0.0", max: "2.x",
                                 createdAt: Date(timeIntervalSince1970: 1_000)))

        let result = store.latestCompatibleRelease(app: "myapp", platform: "ios", channel: "staging",
                                                   nativeVersion: "2.5.0")
        XCTAssertEqual(result?.id, "compatible")
    }

    func testLatestCompatibleReleaseReturnsNilWhenNoneMatch() throws {
        let store = try makeStore()
        try store.insert(release(id: "a", min: "1.0.0", max: "1.x"))

        let result = store.latestCompatibleRelease(app: "myapp", platform: "ios", channel: "staging",
                                                   nativeVersion: "9.0.0")
        XCTAssertNil(result)
    }

    func testReleaseByIdReturnsNilWhenMissing() throws {
        let store = try makeStore()
        XCTAssertNil(store.release(id: "does-not-exist"))
    }

    func testReleaseByIdReturnsMatch() throws {
        let store = try makeStore()
        try store.insert(release(id: "findme"))
        XCTAssertEqual(store.release(id: "findme")?.id, "findme")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Aerospace.xcodeproj -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/SQLiteInjectorReleaseStoreTests`
Expected: **BUILD FAILED**, `cannot find 'SQLiteInjectorReleaseStore' in scope`.

- [ ] **Step 3: Implement `SQLiteInjectorReleaseStore`**

Create `Aerospace/Storage/SQLiteInjectorReleaseStore.swift`:

```swift
//
//  SQLiteInjectorReleaseStore.swift
//  Aerospace
//
//  Thread-safe SQLite persistence for Injector release metadata, built
//  directly on the system SQLite3 C library (no third-party dependencies).
//  Bundle binaries live as flat files on disk; only metadata is stored here.
//  `SQLiteError` is defined in SQLiteLogStore.swift and reused as-is.
//

import Foundation
import SQLite3

private nonisolated(unsafe) let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated final class SQLiteInjectorReleaseStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.networkten.aerospace.injector.sqlite")

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw SQLiteError.open(message)
        }
        db = handle
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA busy_timeout = 3000;")
        try createSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func createSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS releases (
            id TEXT PRIMARY KEY,
            app TEXT NOT NULL,
            platform TEXT NOT NULL,
            channel TEXT NOT NULL,
            version TEXT NOT NULL,
            min_native_version TEXT NOT NULL,
            max_native_version TEXT NOT NULL,
            bundle_hash TEXT NOT NULL,
            bundle_path TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """)
        try exec("""
        CREATE INDEX IF NOT EXISTS idx_releases_target
        ON releases(app, platform, channel, created_at);
        """)
    }

    // MARK: - Writes

    func insert(_ release: InjectorRelease) throws {
        try queue.sync {
            let sql = """
            INSERT OR REPLACE INTO releases
            (id, app, platform, channel, version, min_native_version, max_native_version,
             bundle_hash, bundle_path, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, release.id)
            bindText(stmt, 2, release.app)
            bindText(stmt, 3, release.platform)
            bindText(stmt, 4, release.channel)
            bindText(stmt, 5, release.version)
            bindText(stmt, 6, release.minNativeVersion)
            bindText(stmt, 7, release.maxNativeVersion)
            bindText(stmt, 8, release.bundleHash)
            bindText(stmt, 9, release.bundlePath)
            sqlite3_bind_double(stmt, 10, release.createdAt.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw SQLiteError.step(lastMessage())
            }
        }
    }

    // MARK: - Reads

    private static let selectColumns = """
    id, app, platform, channel, version, min_native_version, max_native_version,
    bundle_hash, bundle_path, created_at
    """

    func fetchAll() -> [InjectorRelease] {
        (try? queue.sync {
            let stmt = try prepare("SELECT \(Self.selectColumns) FROM releases ORDER BY created_at DESC;")
            defer { sqlite3_finalize(stmt) }
            var results: [InjectorRelease] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(row(from: stmt))
            }
            return results
        }) ?? []
    }

    /// All releases targeting `app + platform + channel`, newest first.
    func releases(app: String, platform: String, channel: String) -> [InjectorRelease] {
        (try? queue.sync {
            let stmt = try prepare("""
            SELECT \(Self.selectColumns) FROM releases
            WHERE app = ? AND platform = ? AND channel = ?
            ORDER BY created_at DESC;
            """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, app)
            bindText(stmt, 2, platform)
            bindText(stmt, 3, channel)
            var results: [InjectorRelease] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(row(from: stmt))
            }
            return results
        }) ?? []
    }

    /// The newest release targeting `app + platform + channel` whose native
    /// version range covers `nativeVersion`, or nil if none match.
    func latestCompatibleRelease(app: String, platform: String, channel: String,
                                 nativeVersion: String) -> InjectorRelease? {
        releases(app: app, platform: platform, channel: channel)
            .first { $0.isCompatible(withNativeVersion: nativeVersion) }
    }

    func release(id: String) -> InjectorRelease? {
        try? queue.sync {
            let stmt = try prepare("SELECT \(Self.selectColumns) FROM releases WHERE id = ? LIMIT 1;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return row(from: stmt)
        } ?? nil
    }

    // MARK: - Low-level helpers

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.step(lastMessage())
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepare(lastMessage())
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    private func row(from stmt: OpaquePointer?) -> InjectorRelease {
        InjectorRelease(
            id: columnText(stmt, 0),
            app: columnText(stmt, 1),
            platform: columnText(stmt, 2),
            channel: columnText(stmt, 3),
            version: columnText(stmt, 4),
            minNativeVersion: columnText(stmt, 5),
            maxNativeVersion: columnText(stmt, 6),
            bundleHash: columnText(stmt, 7),
            bundlePath: columnText(stmt, 8),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        )
    }

    private func lastMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project Aerospace.xcodeproj -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/SQLiteInjectorReleaseStoreTests`
Expected: `** TEST SUCCEEDED **`, all 7 test cases passed.

- [ ] **Step 5: Commit**

```bash
git add Aerospace/Storage/SQLiteInjectorReleaseStore.swift AerospaceTests/SQLiteInjectorReleaseStoreTests.swift
git commit -m "Add SQLite-backed release metadata store for Injector"
```

---

### Task 3: HTTP server (routing + Network.framework listener)

**Files:**
- Create: `Aerospace/Server/HTTPInjectorServer.swift`
- Test: `AerospaceTests/InjectorRouteTests.swift`

**Interfaces:**
- Consumes: `ServerState` and `HTTPRequestParser`/`HTTPRequest` (already defined in `Aerospace/Server/HTTPLogServer.swift` and `Aerospace/Server/HTTPRequestParser.swift`, both internal-visibility, reused as-is — do not redeclare).
- Produces: `InjectorRoute` (enum: `.check(app:platform:channel:nativeVersion:)`, `.bundleDownload(releaseId:)`, `.health`, `.options`, `.badRequest(String)`, `.notFound`) and `InjectorRoute.match(method: String, path: String) -> InjectorRoute`; `InjectorCheckResult` (struct: `id, version, bundleHash: String`); `HTTPInjectorServer` class with `var onCheck: (@Sendable (String, String, String, String) -> InjectorCheckResult?)?`, `var onBundleRequest: (@Sendable (String) -> Data?)?`, `var onStateChange: (@Sendable (ServerState) -> Void)?`, `.start(port: UInt16)`, `.stop()`. Task 4 depends on these exact closure signatures.

Only the pure `InjectorRoute.match` routing logic is unit tested here — mirroring this codebase's existing convention where `HTTPRequestParser` (pure) has tests but `HTTPLogServer` (real sockets) does not. The actual networking is verified manually with `curl` in Task 5, once `InjectorStore` wires a running server end-to-end.

- [ ] **Step 1: Write the failing tests for `InjectorRoute`**

Create `AerospaceTests/InjectorRouteTests.swift`:

```swift
//
//  InjectorRouteTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class InjectorRouteTests: XCTestCase {

    func testMatchesCheckWithAllParams() {
        let route = InjectorRoute.match(method: "GET",
            path: "/injector/check?app=myapp&platform=ios&channel=staging&nativeVersion=3.2.0")
        XCTAssertEqual(route, .check(app: "myapp", platform: "ios", channel: "staging", nativeVersion: "3.2.0"))
    }

    func testCheckDefaultsNativeVersionWhenMissing() {
        let route = InjectorRoute.match(method: "GET",
            path: "/injector/check?app=myapp&platform=ios&channel=staging")
        XCTAssertEqual(route, .check(app: "myapp", platform: "ios", channel: "staging", nativeVersion: "0"))
    }

    func testCheckMissingRequiredParamIsBadRequest() {
        let route = InjectorRoute.match(method: "GET", path: "/injector/check?app=myapp")
        guard case .badRequest = route else {
            return XCTFail("Expected .badRequest, got \(route)")
        }
    }

    func testMatchesBundleDownload() {
        let route = InjectorRoute.match(method: "GET", path: "/injector/bundle/abc-123")
        XCTAssertEqual(route, .bundleDownload(releaseId: "abc-123"))
    }

    func testMatchesHealth() {
        XCTAssertEqual(InjectorRoute.match(method: "GET", path: "/health"), .health)
        XCTAssertEqual(InjectorRoute.match(method: "HEAD", path: "/health"), .health)
    }

    func testMatchesOptions() {
        XCTAssertEqual(InjectorRoute.match(method: "OPTIONS", path: "/injector/check"), .options)
    }

    func testUnknownRouteIsNotFound() {
        XCTAssertEqual(InjectorRoute.match(method: "GET", path: "/nope"), .notFound)
    }

    func testPostToCheckIsNotFound() {
        XCTAssertEqual(InjectorRoute.match(method: "POST", path: "/injector/check"), .notFound)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Aerospace.xcodeproj -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/InjectorRouteTests`
Expected: **BUILD FAILED**, `cannot find 'InjectorRoute' in scope`.

- [ ] **Step 3: Implement `InjectorRoute` and `HTTPInjectorServer`**

Create `Aerospace/Server/HTTPInjectorServer.swift`:

```swift
//
//  HTTPInjectorServer.swift
//  Aerospace
//
//  A tiny HTTP server built on Apple's Network framework (no third-party
//  dependencies), serving Injector's release-check and bundle-download
//  routes. Structurally mirrors HTTPLogServer but is a separate listener on
//  its own port, kept independent so Logger's server is untouched.
//

import Foundation
import Network

/// The result of matching an incoming request to an Injector route. Pure
/// and network-free so routing logic can be unit tested directly.
nonisolated enum InjectorRoute: Equatable {
    case check(app: String, platform: String, channel: String, nativeVersion: String)
    case bundleDownload(releaseId: String)
    case health
    case options
    case badRequest(String)
    case notFound

    private static let bundlePrefix = "/injector/bundle/"

    static func match(method: String, path: String) -> InjectorRoute {
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path

        switch (method, pathOnly) {
        case ("GET", "/injector/check"):
            let query = queryParameters(from: path)
            guard let app = query["app"], let platform = query["platform"],
                  let channel = query["channel"] else {
                return .badRequest("Missing required query parameter: app, platform, or channel")
            }
            return .check(app: app, platform: platform, channel: channel,
                         nativeVersion: query["nativeVersion"] ?? "0")
        case ("GET", let p) where p.hasPrefix(bundlePrefix):
            return .bundleDownload(releaseId: String(p.dropFirst(bundlePrefix.count)))
        case ("GET", "/health"), ("HEAD", "/health"):
            return .health
        case ("OPTIONS", _):
            return .options
        default:
            return .notFound
        }
    }

    private static func queryParameters(from pathAndQuery: String) -> [String: String] {
        guard let components = URLComponents(string: pathAndQuery) else { return [:] }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            result[item.name] = item.value
        }
        return result
    }
}

/// What `HTTPInjectorServer.onCheck` returns for a matching release. The
/// download URL is assembled by the server itself (it alone knows its bound
/// port), not by the caller.
nonisolated struct InjectorCheckResult: Equatable, Sendable {
    let id: String
    let version: String
    let bundleHash: String
}

nonisolated final class HTTPInjectorServer: @unchecked Sendable {
    /// Called on the server's queue to answer a `/injector/check` request.
    /// Return nil if no release matches.
    var onCheck: (@Sendable (_ app: String, _ platform: String, _ channel: String,
                            _ nativeVersion: String) -> InjectorCheckResult?)?
    /// Called on the server's queue to answer a `/injector/bundle/<id>`
    /// request. Return nil if no bundle exists for that release id.
    var onBundleRequest: (@Sendable (_ releaseId: String) -> Data?)?
    /// Called on the server's queue whenever the listener state changes.
    var onStateChange: (@Sendable (ServerState) -> Void)?

    private let queue = DispatchQueue(label: "com.networkten.aerospace.injectorserver")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private static let maxBodySize = 1024

    // MARK: - Lifecycle

    func start(port: UInt16) {
        queue.async { [self] in
            stopLocked()
            emit(.starting)

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                emit(.failed("Invalid port \(port)"))
                return
            }

            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            let newListener: NWListener
            do {
                newListener = try NWListener(using: params, on: nwPort)
            } catch {
                emit(.failed(error.localizedDescription))
                return
            }

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let boundPort = self.listener?.port?.rawValue ?? port
                    self.emit(.running(port: boundPort))
                case .failed(let error):
                    self.emit(.failed(error.localizedDescription))
                    self.stop()
                case .cancelled:
                    self.emit(.stopped)
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }

            listener = newListener
            newListener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in stopLocked() }
    }

    private func stopLocked() {
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func emit(_ state: ServerState) {
        onStateChange?(state)
    }

    // MARK: - Connections

    private func handle(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        let parser = HTTPRequestParser(maxBodySize: Self.maxBodySize)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.connections[key] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, parser: parser, key: key)
    }

    private func receive(on connection: NWConnection, parser: HTTPRequestParser,
                         key: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                parser.append(data)
                self.drain(connection, parser: parser, key: key)
            }

            if isComplete || error != nil {
                connection.cancel()
                self.queue.async { self.connections[key] = nil }
                return
            }
            self.receive(on: connection, parser: parser, key: key)
        }
    }

    private func drain(_ connection: NWConnection, parser: HTTPRequestParser,
                       key: ObjectIdentifier) {
        while true {
            let request: HTTPRequest?
            do {
                request = try parser.takeRequest()
            } catch {
                respond(connection, status: 400, reason: "Bad Request",
                        json: ["error": "\(error)"], close: true)
                return
            }
            guard let request else { return }
            route(request, on: connection)
        }
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        switch InjectorRoute.match(method: request.method, path: request.path) {
        case .check(let app, let platform, let channel, let nativeVersion):
            guard let result = onCheck?(app, platform, channel, nativeVersion) else {
                respond(connection, status: 204, reason: "No Content", json: nil)
                return
            }
            let port = listener?.port?.rawValue ?? 0
            respond(connection, status: 200, reason: "OK", json: [
                "id": result.id,
                "version": result.version,
                "bundleHash": result.bundleHash,
                "downloadUrl": "http://localhost:\(port)/injector/bundle/\(result.id)",
            ])
        case .bundleDownload(let releaseId):
            guard let data = onBundleRequest?(releaseId) else {
                respond(connection, status: 404, reason: "Not Found",
                        json: ["error": "No bundle for release \(releaseId)"])
                return
            }
            respondBinary(connection, status: 200, reason: "OK", data: data)
        case .health:
            respond(connection, status: 200, reason: "OK", json: ["status": "healthy"])
        case .options:
            respond(connection, status: 204, reason: "No Content", json: nil)
        case .badRequest(let message):
            respond(connection, status: 400, reason: "Bad Request", json: ["error": message])
        case .notFound:
            respond(connection, status: 404, reason: "Not Found",
                    json: ["error": "No route for \(request.method) \(request.path)"])
        }
    }

    // MARK: - Responses

    private func respond(_ connection: NWConnection, status: Int, reason: String,
                         json: [String: String]?, close: Bool = false) {
        var body = Data()
        if let json,
           let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            body = data
        }
        sendResponse(connection, status: status, reason: reason, contentType: "application/json",
                    body: body, close: close)
    }

    private func respondBinary(_ connection: NWConnection, status: Int, reason: String, data: Data) {
        sendResponse(connection, status: status, reason: reason,
                    contentType: "application/octet-stream", body: data, close: false)
    }

    private func sendResponse(_ connection: NWConnection, status: Int, reason: String,
                              contentType: String, body: Data, close: Bool) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: Content-Type\r\n"
        head += "Access-Control-Allow-Methods: GET, OPTIONS\r\n"
        if close { head += "Connection: close\r\n" }
        head += "\r\n"

        var response = Data(head.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project Aerospace.xcodeproj -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/InjectorRouteTests`
Expected: `** TEST SUCCEEDED **`, all 8 test cases passed.

- [ ] **Step 5: Commit**

```bash
git add Aerospace/Server/HTTPInjectorServer.swift AerospaceTests/InjectorRouteTests.swift
git commit -m "Add Injector HTTP server with /injector/check and /injector/bundle routes"
```

---

### Task 4: InjectorStore facade (publish flow, wiring)

**Files:**
- Create: `Aerospace/Storage/InjectorStore.swift`
- Test: `AerospaceTests/InjectorStoreTests.swift`

**Interfaces:**
- Consumes: `InjectorRelease`, `InjectorVersion` (Task 1); `SQLiteInjectorReleaseStore` (Task 2); `HTTPInjectorServer`, `InjectorCheckResult`, `ServerState` (Task 3).
- Produces: `InjectorStore` (`@MainActor final class ... ObservableObject`) with `init(store: SQLiteInjectorReleaseStore? = nil, bundlesDirectory: URL? = nil, defaults: UserDefaults = .standard)`, `@Published private(set) var releases: [InjectorRelease]`, `@Published private(set) var serverState: ServerState`, `@Published private(set) var publishError: String?`, `@Published var port: UInt16`, `.startServer()`, `.stopServer()`, `.restartServer()`, `.publish(bundleURL: URL, app: String, platform: String, channel: String, version: String, minNativeVersion: String, maxNativeVersion: String) -> Bool`. Task 5's views depend on these exact property and method names.

- [ ] **Step 1: Write the failing tests**

Create `AerospaceTests/InjectorStoreTests.swift`:

```swift
//
//  InjectorStoreTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class InjectorStoreTests: XCTestCase {

    private func makeStore() throws -> InjectorStore {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("injector-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dbPath = base.appendingPathComponent("injector.sqlite").path
        let bundlesDir = base.appendingPathComponent("bundles", isDirectory: true)
        let sqliteStore = try SQLiteInjectorReleaseStore(path: dbPath)
        let defaults = UserDefaults(suiteName: "InjectorStoreTests-\(UUID().uuidString)")!
        return InjectorStore(store: sqliteStore, bundlesDirectory: bundlesDir, defaults: defaults)
    }

    private func writeTestBundle(named name: String = "main.jsbundle",
                                content: String = "console.log('hi')") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @MainActor
    func testPublishSucceedsAndAppearsInReleases() throws {
        let store = try makeStore()
        let bundleURL = try writeTestBundle()

        let ok = store.publish(bundleURL: bundleURL, app: "myapp", platform: "ios", channel: "staging",
                               version: "1", minNativeVersion: "1.0.0", maxNativeVersion: "1.x")

        XCTAssertTrue(ok)
        XCTAssertNil(store.publishError)
        XCTAssertEqual(store.releases.count, 1)
        XCTAssertEqual(store.releases.first?.app, "myapp")
    }

    @MainActor
    func testPublishRejectsInvertedNativeVersionRange() throws {
        let store = try makeStore()
        let bundleURL = try writeTestBundle()

        let ok = store.publish(bundleURL: bundleURL, app: "myapp", platform: "ios", channel: "staging",
                               version: "1", minNativeVersion: "2.0.0", maxNativeVersion: "1.0.0")

        XCTAssertFalse(ok)
        XCTAssertEqual(store.releases.count, 0)
        XCTAssertNotNil(store.publishError)
    }

    @MainActor
    func testPublishRejectsUnreadableBundleFile() throws {
        let store = try makeStore()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist.bundle")

        let ok = store.publish(bundleURL: missingURL, app: "myapp", platform: "ios", channel: "staging",
                               version: "1", minNativeVersion: "1.0.0", maxNativeVersion: "1.x")

        XCTAssertFalse(ok)
        XCTAssertNotNil(store.publishError)
    }

    @MainActor
    func testPublishedBundleContentIsCopiedByteForByte() throws {
        let store = try makeStore()
        let content = "console.log('exact bytes')"
        let bundleURL = try writeTestBundle(content: content)

        _ = store.publish(bundleURL: bundleURL, app: "myapp", platform: "ios", channel: "staging",
                          version: "1", minNativeVersion: "1.0.0", maxNativeVersion: "1.x")

        let stored = try XCTUnwrap(store.releases.first)
        let copied = try String(contentsOfFile: stored.bundlePath, encoding: .utf8)
        XCTAssertEqual(copied, content)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project Aerospace.xcodeproj -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/InjectorStoreTests`
Expected: **BUILD FAILED**, `cannot find 'InjectorStore' in scope`.

- [ ] **Step 3: Implement `InjectorStore`**

Create `Aerospace/Storage/InjectorStore.swift`:

```swift
//
//  InjectorStore.swift
//  Aerospace
//
//  The observable application state for the Injector tool: owns the SQLite
//  release-metadata store, the HTTP server, and the on-disk bundle file
//  storage. Publishing a release copies the bundle file, hashes it, and
//  inserts a metadata row. The HTTP server answers /injector/check and
//  /injector/bundle/<id> by reading straight from the (thread-safe) SQLite
//  store and disk, bypassing the main actor entirely for that hot path.
//

import Foundation
import Combine
import CryptoKit

@MainActor
final class InjectorStore: ObservableObject {

    @Published private(set) var releases: [InjectorRelease] = []
    @Published private(set) var serverState: ServerState = .stopped
    @Published private(set) var publishError: String?

    @Published var port: UInt16 {
        didSet { defaults.set(Int(port), forKey: Keys.port) }
    }

    private nonisolated let store: SQLiteInjectorReleaseStore
    private nonisolated let bundlesDirectory: URL
    private let server = HTTPInjectorServer()
    private let defaults: UserDefaults

    private enum Keys {
        static let port = "injector.port"
    }

    init(store: SQLiteInjectorReleaseStore? = nil, bundlesDirectory: URL? = nil,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.port = UInt16(defaults.object(forKey: Keys.port) as? Int ?? 57334)
        self.store = store ?? Self.makeDefaultStore()
        self.bundlesDirectory = bundlesDirectory ?? Self.makeDefaultBundlesDirectory()
        try? FileManager.default.createDirectory(at: self.bundlesDirectory,
                                                 withIntermediateDirectories: true)
        wireServer()
        refreshReleases()
    }

    private static func makeDefaultStore() -> SQLiteInjectorReleaseStore {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Aerospace", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("injector.sqlite").path
        do {
            return try SQLiteInjectorReleaseStore(path: path)
        } catch {
            let tmp = fm.temporaryDirectory.appendingPathComponent("aerospace-injector.sqlite").path
            return (try? SQLiteInjectorReleaseStore(path: tmp))
                ?? (try! SQLiteInjectorReleaseStore(path: ":memory:"))
        }
    }

    private static func makeDefaultBundlesDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("Aerospace", isDirectory: true)
            .appendingPathComponent("InjectorBundles", isDirectory: true)
    }

    // MARK: - Server control

    private func wireServer() {
        server.onCheck = { [store] app, platform, channel, nativeVersion in
            guard let release = store.latestCompatibleRelease(
                app: app, platform: platform, channel: channel, nativeVersion: nativeVersion
            ) else { return nil }
            return InjectorCheckResult(id: release.id, version: release.version,
                                       bundleHash: release.bundleHash)
        }
        server.onBundleRequest = { [store] releaseId in
            guard let release = store.release(id: releaseId) else { return nil }
            return try? Data(contentsOf: URL(fileURLWithPath: release.bundlePath))
        }
        server.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in self?.serverState = state }
        }
    }

    func startServer() {
        server.start(port: port)
    }

    func stopServer() {
        server.stop()
    }

    func restartServer() {
        server.stop()
        server.start(port: port)
    }

    // MARK: - Publishing

    /// Imports `bundleURL` into Injector's storage, tags it, and records it
    /// as a new release. Returns whether publishing succeeded; on failure,
    /// `publishError` explains why.
    @discardableResult
    func publish(bundleURL: URL, app: String, platform: String, channel: String, version: String,
                minNativeVersion: String, maxNativeVersion: String) -> Bool {
        publishError = nil

        guard InjectorVersion.isOrdered(minNativeVersion, lessOrEqualTo: maxNativeVersion) else {
            publishError = "Minimum native version must not exceed maximum native version."
            return false
        }

        let data: Data
        do {
            data = try Data(contentsOf: bundleURL)
        } catch {
            publishError = "Could not read bundle file: \(error.localizedDescription)"
            return false
        }

        let id = UUID().uuidString
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let destinationDir = bundlesDirectory.appendingPathComponent(id, isDirectory: true)
        let destinationFile = destinationDir.appendingPathComponent(bundleURL.lastPathComponent)

        do {
            try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            try data.write(to: destinationFile)
            let release = InjectorRelease(
                id: id, app: app, platform: platform, channel: channel, version: version,
                minNativeVersion: minNativeVersion, maxNativeVersion: maxNativeVersion,
                bundleHash: hash, bundlePath: destinationFile.path, createdAt: Date()
            )
            try store.insert(release)
        } catch {
            publishError = "Publish failed: \(error.localizedDescription)"
            return false
        }

        refreshReleases()
        return true
    }

    private func refreshReleases() {
        releases = store.fetchAll()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project Aerospace.xcodeproj -scheme Aerospace -destination 'platform=macOS' -only-testing:AerospaceTests/InjectorStoreTests`
Expected: `** TEST SUCCEEDED **`, all 4 test cases passed.

- [ ] **Step 5: Commit**

```bash
git add Aerospace/Storage/InjectorStore.swift AerospaceTests/InjectorStoreTests.swift
git commit -m "Add InjectorStore facade wiring the release store and HTTP server"
```

---

### Task 5: SwiftUI views, sidebar wiring, and end-to-end verification

**Files:**
- Create: `Aerospace/Views/InjectorPublishForm.swift`
- Create: `Aerospace/Views/InjectorReleaseListView.swift`
- Create: `Aerospace/Views/InjectorToolView.swift`
- Modify: `Aerospace/Views/RootView.swift` (add `.injector` case)
- Modify: `Aerospace/AerospaceApp.swift` (add `injectorStore`, start its server)

**Interfaces:**
- Consumes: `InjectorStore`, `InjectorRelease` (Task 4, Task 1).
- Produces: `InjectorPublishForm`, `InjectorReleaseListView`, `InjectorToolView`, `InjectorStatusBar` (all `View`); `Tool.injector` case.

This codebase has no unit tests for SwiftUI views (only `#Preview` blocks) — verification here is a build check plus a manual run-through, consistent with existing convention.

- [ ] **Step 1: Add the publish form view**

Create `Aerospace/Views/InjectorPublishForm.swift`:

```swift
//
//  InjectorPublishForm.swift
//  Aerospace
//
//  The publish form: pick a built JS bundle file, tag it with its target
//  app/platform/channel/native-version range, and publish it as a new
//  release.
//

import SwiftUI
import UniformTypeIdentifiers

struct InjectorPublishForm: View {
    @EnvironmentObject private var store: InjectorStore

    @State private var bundleURL: URL?
    @State private var app = ""
    @State private var platform = "ios"
    @State private var channel = "staging"
    @State private var version = ""
    @State private var minNativeVersion = ""
    @State private var maxNativeVersion = ""

    var body: some View {
        Form {
            Section("Bundle") {
                Button {
                    chooseBundle()
                } label: {
                    Label(bundleURL?.lastPathComponent ?? "Choose Bundle File…",
                         systemImage: "doc.badge.plus")
                }
                if let bundleURL {
                    Text(bundleURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section("Target") {
                TextField("App", text: $app)
                Picker("Platform", selection: $platform) {
                    Text("iOS").tag("ios")
                    Text("Android").tag("android")
                }
                TextField("Channel", text: $channel)
                TextField("Version", text: $version)
                TextField("Min Native Version", text: $minNativeVersion)
                TextField("Max Native Version", text: $maxNativeVersion)
            }

            if let publishError = store.publishError {
                Text(publishError).font(.caption).foregroundStyle(.red)
            }

            Button("Publish") { publish() }
                .disabled(!canPublish)
        }
        .formStyle(.grouped)
        .navigationTitle("Publish")
    }

    private var canPublish: Bool {
        bundleURL != nil && !app.isEmpty && !channel.isEmpty && !version.isEmpty
            && !minNativeVersion.isEmpty && !maxNativeVersion.isEmpty
    }

    private func chooseBundle() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            bundleURL = url
        }
    }

    private func publish() {
        guard let bundleURL else { return }
        let published = store.publish(
            bundleURL: bundleURL, app: app, platform: platform, channel: channel, version: version,
            minNativeVersion: minNativeVersion, maxNativeVersion: maxNativeVersion)
        if published {
            self.bundleURL = nil
            version = ""
        }
    }
}

#Preview {
    InjectorPublishForm().environmentObject(InjectorStore())
}
```

- [ ] **Step 2: Add the release history view**

Create `Aerospace/Views/InjectorReleaseListView.swift`:

```swift
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
```

- [ ] **Step 3: Add the tool container view and status bar**

Create `Aerospace/Views/InjectorToolView.swift`:

```swift
//
//  InjectorToolView.swift
//  Aerospace
//
//  The Injector tool: a publish form beside the release history, with a
//  persistent server-status bar along the bottom. Presented in the detail
//  area of the top-level tool navigator.
//

import SwiftUI

struct InjectorToolView: View {
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                InjectorPublishForm()
                    .frame(minWidth: 300, idealWidth: 340)
                InjectorReleaseListView()
                    .frame(minWidth: 400)
            }
            Divider()
            InjectorStatusBar()
        }
    }
}

/// A compact status bar showing the server state, port, and release count.
struct InjectorStatusBar: View {
    @EnvironmentObject private var store: InjectorStore

    private var indicatorColor: Color {
        switch store.serverState {
        case .running: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 9, height: 9)
            Text(store.serverState.description)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Label("\(store.releases.count)", systemImage: "shippingbox")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Total releases published")

            if store.serverState.isRunning {
                Button {
                    store.stopServer()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button {
                    store.startServer()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

#Preview {
    InjectorToolView().environmentObject(InjectorStore())
}
```

- [ ] **Step 4: Wire the `.injector` case into `RootView`**

In `Aerospace/Views/RootView.swift`, replace the `Tool` enum (lines 11–37) with:

```swift
enum Tool: String, CaseIterable, Identifiable, Hashable {
    case logger
    case apiTester
    case injector

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logger: return "Logger"
        case .apiTester: return "API Tester"
        case .injector: return "Injector"
        }
    }

    var systemImage: String {
        switch self {
        case .logger: return "doc.text.magnifyingglass"
        case .apiTester: return "paperplane"
        case .injector: return "shippingbox"
        }
    }

    var subtitle: String {
        switch self {
        case .logger: return "Receive & inspect logs"
        case .apiTester: return "Build & send requests"
        case .injector: return "Publish OTA bundles"
        }
    }
}
```

Then replace the `detail:` switch (lines 59–66) with:

```swift
        } detail: {
            switch selectedTool {
            case .logger:
                LoggerToolView()
            case .apiTester:
                APITesterView()
            case .injector:
                InjectorToolView()
            }
        }
```

Then replace the `#Preview` block (lines 70–75) with:

```swift
#Preview {
    RootView()
        .environmentObject(LogStore())
        .environmentObject(APITesterStore())
        .environmentObject(InjectorStore())
        .frame(width: 1000, height: 640)
}
```

- [ ] **Step 5: Wire `InjectorStore` into the app entry point**

In `Aerospace/AerospaceApp.swift`, replace the whole file with:

```swift
//
//  AerospaceApp.swift
//  Aerospace
//
//  Entry point. Owns the shared LogStore and starts the HTTP log server
//  when the app launches.
//

import SwiftUI

@main
struct AerospaceApp: App {
    @StateObject private var store = LogStore()
    @StateObject private var apiStore = APITesterStore()
    @StateObject private var injectorStore = InjectorStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(apiStore)
                .environmentObject(injectorStore)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    store.startServer()
                    injectorStore.startServer()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Restart Server") { store.restartServer() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
```

- [ ] **Step 6: Build the app**

Run: `xcodebuild build -project Aerospace.xcodeproj -scheme Aerospace -configuration Debug -destination 'platform=macOS'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Run the full Injector test suite**

Run each of:
```bash
xcodebuild test -project Aerospace.xcodeproj -scheme Aerospace -destination 'platform=macOS' \
  -only-testing:AerospaceTests/InjectorVersionTests \
  -only-testing:AerospaceTests/InjectorReleaseTests \
  -only-testing:AerospaceTests/SQLiteInjectorReleaseStoreTests \
  -only-testing:AerospaceTests/InjectorRouteTests \
  -only-testing:AerospaceTests/InjectorStoreTests
```
Expected: `** TEST SUCCEEDED **`, all test cases across all five classes passed.

- [ ] **Step 8: Manually verify the running app end-to-end**

This step needs a human (or the `run` skill) at the keyboard — SwiftUI app interaction can't be scripted from the command line.

1. Launch the built app: `open ~/Library/Developer/Xcode/DerivedData/Aerospace-*/Build/Products/Debug/Aerospace.app`
2. Confirm "Injector" appears as a third sidebar entry, with the release-history "No Releases Yet" empty state showing.
3. Confirm the status bar at the bottom shows "Listening on port 57334" (it auto-starts on launch).
4. Create a small test bundle file from a terminal: `echo "console.log('test bundle')" > /tmp/test-main.jsbundle`
5. In the Injector tool: choose that file, fill in App=`testapp`, Platform=`iOS`, Channel=`staging`, Version=`1`, Min Native Version=`1.0.0`, Max Native Version=`1.x`, then click Publish.
6. Confirm the release now appears in the history list, and the status bar's release count increments to 1.
7. From a terminal, verify the HTTP API directly:
   ```bash
   curl -s "http://localhost:57334/injector/check?app=testapp&platform=ios&channel=staging&nativeVersion=1.2.0"
   ```
   Expected: a JSON body with `id`, `version: "1"`, `bundleHash`, and a `downloadUrl` pointing at `/injector/bundle/<id>`.
8. Follow the `downloadUrl` from the previous response and confirm it returns the original file's bytes:
   ```bash
   curl -s "http://localhost:57334/injector/bundle/<id-from-step-7>"
   ```
   Expected output: `console.log('test bundle')`.
9. Verify a non-matching request returns no content:
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:57334/injector/check?app=testapp&platform=ios&channel=staging&nativeVersion=9.0.0"
   ```
   Expected: `204`.

- [ ] **Step 9: Commit**

```bash
git add Aerospace/Views/InjectorPublishForm.swift Aerospace/Views/InjectorReleaseListView.swift \
        Aerospace/Views/InjectorToolView.swift Aerospace/Views/RootView.swift Aerospace/AerospaceApp.swift
git commit -m "Add Injector tool to the sidebar and wire its server into app launch"
```

---

## Self-Review Notes

**Spec coverage:** Every section of `docs/superpowers/specs/2026-07-10-injector-design.md`'s "Aerospace side" scope is covered — data model (Task 1–2), HTTP API (Task 3), publish flow + error handling (Task 4), UI + wiring (Task 5), manual + automated testing (all tasks + Task 5 Step 8). The RN client SDK, rollout percentages, remote hosting, and crash reporting are out of scope per the spec and are not present in this plan.

**Type consistency:** `InjectorRelease`'s fields (`id, app, platform, channel, version, minNativeVersion, maxNativeVersion, bundleHash, bundlePath, createdAt`) are used identically across Tasks 1, 2, 4, and 5. `InjectorCheckResult`'s fields (`id, version, bundleHash`) match between Task 3's definition and Task 4's construction. `HTTPInjectorServer`'s closure signatures match between Task 3's declaration and Task 4's assignment.

**No placeholders:** All code blocks are complete, compilable implementations; no `TODO`/`TBD` remain.
