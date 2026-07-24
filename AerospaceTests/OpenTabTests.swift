import XCTest
@testable import Aerospace

final class OpenTabTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let req = SavedRequest(name: "R", urlString: "https://x")
        let tab = OpenTab(requestID: req.id, request: req)
        XCTAssertEqual(tab.requestID, req.id)
        XCTAssertFalse(tab.isPreview)

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(OpenTab.self, from: data)
        XCTAssertEqual(decoded, tab)
    }

    func testEphemeralTabHasNilRequestID() throws {
        let tab = OpenTab(request: SavedRequest(name: "E", urlString: "https://y"))
        XCTAssertNil(tab.requestID)
    }
}
