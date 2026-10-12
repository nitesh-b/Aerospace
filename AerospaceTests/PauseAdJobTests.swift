//
//  PauseAdJobTests.swift
//  AerospaceTests
//

import XCTest
@testable import Aerospace

final class PauseAdJobTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func job(_ type: PauseAdType = .sales, folder: String = "specsavers",
                     code: String = "19583", on day: Date? = nil) throws -> PauseAdJob {
        try PauseAdJob.make(adType: type, folderName: folder, jobCode: code,
                            date: day ?? date(2026, 10, 12), calendar: calendar)
    }

    // MARK: - Month folder (parity with setup-s/h: MM + en-GB short month)

    func testMonthFolderMatchesNodeEnGBShortMonth() {
        let expected = ["01Jan", "02Feb", "03Mar", "04Apr", "05May", "06Jun",
                        "07Jul", "08Aug", "09Sept", "10Oct", "11Nov", "12Dec"]
        let actual = (1...12).map { PauseAdJob.monthFolder(for: date(2026, $0, 15), calendar: calendar) }
        XCTAssertEqual(actual, expected)
    }

    func testMonthFolderUsesCalendarTimeZone() {
        // 2026-10-31 23:30 UTC is already 1 Nov in Sydney.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let instant = utc.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23, minute: 30))!
        XCTAssertEqual(PauseAdJob.monthFolder(for: instant, calendar: utc), "10Oct")
        XCTAssertEqual(PauseAdJob.monthFolder(for: instant, calendar: calendar), "11Nov")
    }

    // MARK: - Ticket normalization

    func testTicketGetsPrefix() {
        XCTAssertEqual(PauseAdJob.normalizeTicket("19583"), "p-19583")
    }

    func testTicketKeepsExistingPrefix() {
        XCTAssertEqual(PauseAdJob.normalizeTicket("p-19583"), "p-19583")
    }

    func testUppercaseTicketPrefixIsNotDoubled() {
        XCTAssertEqual(PauseAdJob.normalizeTicket("P-19583"), "p-19583")
    }

    func testTicketIsTrimmed() {
        XCTAssertEqual(PauseAdJob.normalizeTicket("  19583 \n"), "p-19583")
    }

    // MARK: - make / validation

    func testMakeBuildsSetupPath() throws {
        let j = try job()
        XCTAssertEqual(j.relativePath, "ads/sales/2026/specsavers/10Oct/pause/p-19583")
    }

    func testMakeHouseAd() throws {
        let j = try job(.house, folder: "bigbrother", code: "P-17001", on: date(2026, 9, 1))
        XCTAssertEqual(j.relativePath, "ads/house/2026/bigbrother/09Sept/pause/p-17001")
    }

    func testMakeTrimsFolderName() throws {
        XCTAssertEqual(try job(folder: "  old_el_paso ").folderName, "old_el_paso")
    }

    func testEmptyFolderNameRejected() {
        XCTAssertThrowsError(try job(folder: "  ")) {
            XCTAssertEqual($0 as? PauseAdJob.ValidationError, .emptyFolderName)
        }
    }

    func testFolderNameWithPathCharactersRejected() {
        for bad in ["a/b", "..", ".hidden", "a b", "a\\b", "~x"] {
            XCTAssertThrowsError(try job(folder: bad), bad) {
                XCTAssertEqual($0 as? PauseAdJob.ValidationError, .invalidFolderName, bad)
            }
        }
    }

    func testEmptyJobCodeRejected() {
        for bad in ["", "  ", "p-", "P-"] {
            XCTAssertThrowsError(try job(code: bad), bad) {
                XCTAssertEqual($0 as? PauseAdJob.ValidationError, .emptyJobCode, bad)
            }
        }
    }

    func testJobCodeWithPathCharactersRejected() {
        for bad in ["12/34", "12 34", "../1", "1.2"] {
            XCTAssertThrowsError(try job(code: bad), bad) {
                XCTAssertEqual($0 as? PauseAdJob.ValidationError, .invalidJobCode, bad)
            }
        }
    }

    // MARK: - Suggested folder name

    func testSuggestedFolderName() {
        XCTAssertEqual(PauseAdJob.suggestedFolderName(brand: "Specsavers"), "specsavers")
        XCTAssertEqual(PauseAdJob.suggestedFolderName(brand: "Old El Paso"), "old_el_paso")
        XCTAssertEqual(PauseAdJob.suggestedFolderName(brand: " Big Brother & Co. "), "big_brother_co")
        XCTAssertEqual(PauseAdJob.suggestedFolderName(brand: "7-Eleven"), "7_eleven")
        XCTAssertEqual(PauseAdJob.suggestedFolderName(brand: "L'Oréal"), "l_or_al")
        XCTAssertEqual(PauseAdJob.suggestedFolderName(brand: "  "), "")
    }

    // MARK: - Version-scoped paths

    func testVersionPaths() throws {
        let j = try job()
        let base = "ads/sales/2026/specsavers/10Oct/pause/p-19583/v2"
        XCTAssertEqual(j.versionPath(2), base)
        XCTAssertEqual(j.serverPath(2), base + "/server")
        XCTAssertEqual(j.metadataPath(2), base + "/metadata.json")
        XCTAssertEqual(j.remoteManifestPath(2), base + "/manifests/RemoteManifest")
        XCTAssertEqual(j.hostedMetadataPath(2), base + "/manifests/RemoteManifest/metadata.json")
    }

    // MARK: - Deployment (parity with deployZips)

    func testDeploymentDirectoryMirrorsAdsTreeUnderDeployments() throws {
        XCTAssertEqual(try job().deploymentDirectory(1),
                       "deployments/sales/2026/specsavers/10Oct/pause/p-19583/v1")
    }

    func testDeploymentTitleIsTargetBeforeFirstUnderscore() {
        XCTAssertEqual(PauseAdJob.deploymentTitle(target: "Specsavers-2026-PremiumPause-Ad-25_main"),
                       "Specsavers-2026-PremiumPause-Ad-25")
        XCTAssertEqual(PauseAdJob.deploymentTitle(target: "NoUnderscore"), "NoUnderscore")
        XCTAssertEqual(PauseAdJob.deploymentTitle(target: "A_b_c"), "A")
    }

    func testDeploymentTitleReplacesBracketsAndWhitespace() {
        XCTAssertEqual(PauseAdJob.deploymentTitle(target: "Brand (v2)  Final\tCut_main"),
                       "Brand__v2__Final_Cut")
    }

    func testDeploymentZipNameAppendsDpmDate() throws {
        let j = try job()
        XCTAssertEqual(
            j.deploymentZipPath(1, target: "Specsavers-2026-PremiumPause-Ad-25_main",
                                date: date(2026, 7, 5), calendar: calendar),
            "deployments/sales/2026/specsavers/10Oct/pause/p-19583/v1/Specsavers-2026-PremiumPause-Ad-25-dpm-2026-07-05.zip")
    }

    // MARK: - Parsing an existing relative path

    func testParsesJobRelativePath() throws {
        let parsed = try XCTUnwrap(PauseAdJob(relativePath: "ads/sales/2026/specsavers/09sep/pause/p-19583"))
        XCTAssertEqual(parsed.adType, .sales)
        XCTAssertEqual(parsed.year, "2026")
        XCTAssertEqual(parsed.folderName, "specsavers")
        XCTAssertEqual(parsed.monthFolder, "09sep")
        XCTAssertEqual(parsed.ticket, "p-19583")
        XCTAssertEqual(parsed.relativePath, "ads/sales/2026/specsavers/09sep/pause/p-19583")
    }

    func testParsesPathWithLeadingSlashAndDeeperComponents() throws {
        let parsed = try XCTUnwrap(PauseAdJob(
            relativePath: "/ads/house/2025/dealornodeal/07jul/pause/p-12416/v1/manifests/RemoteManifest/metadata.json"))
        XCTAssertEqual(parsed.relativePath, "ads/house/2025/dealornodeal/07jul/pause/p-12416")
    }

    func testRejectsNonPauseOrUnknownTypePaths() {
        XCTAssertNil(PauseAdJob(relativePath: "ads/testads/2022/x/01jan/pause/p-1"))
        XCTAssertNil(PauseAdJob(relativePath: "ads/house/2021/show/one/server"))
        XCTAssertNil(PauseAdJob(relativePath: "ads/sales/2026/x"))
        XCTAssertNil(PauseAdJob(relativePath: "deployments/sales/2026/x/01Jan/pause/p-1"))
    }

    // MARK: - File system: versions and lookup

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PauseAdJobTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(relative),
                                                withIntermediateDirectories: true)
    }

    func testVersionsEmptyWhenJobMissing() throws {
        let j = try job()
        XCTAssertEqual(j.existingVersions(under: root), [])
        XCTAssertEqual(j.nextVersion(under: root), 1)
    }

    func testVersionsAreNumericallySortedAndIgnoreNoise() throws {
        let j = try job()
        for v in ["v1", "v10", "v2", "vx", "v", "notes"] { try mkdir("\(j.relativePath)/\(v)") }
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("\(j.relativePath)/v3").path, contents: Data())
        XCTAssertEqual(j.existingVersions(under: root), [1, 2, 10])
        XCTAssertEqual(j.nextVersion(under: root), 11)
    }

    func testLocateFindsTicketInAnyMonthAndFolder() throws {
        try mkdir("ads/sales/2026/specsavers/09Sept/pause/p-19583/v1")
        try mkdir("ads/sales/2025/specsavers_old/12dec/pause/p-19583/v1")
        try mkdir("ads/sales/2026/specsavers/09Sept/pause/p-11111/v1")
        try mkdir("ads/house/2026/show/01Jan/pause/p-22222/v1")

        let found = PauseAdJob.locate(ticket: "P-19583", under: root)
        XCTAssertEqual(found.map(\.relativePath), [
            "ads/sales/2025/specsavers_old/12dec/pause/p-19583",
            "ads/sales/2026/specsavers/09Sept/pause/p-19583",
        ])
    }

    func testLocateSearchesHouseToo() throws {
        try mkdir("ads/house/2026/show/01Jan/pause/p-22222")
        XCTAssertEqual(PauseAdJob.locate(ticket: "22222", under: root).map(\.adType), [.house])
    }

    func testLocateReturnsEmptyWithoutAdsFolder() {
        XCTAssertEqual(PauseAdJob.locate(ticket: "1", under: root), [])
    }
}
