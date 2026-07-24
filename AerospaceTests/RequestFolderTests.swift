import XCTest
@testable import Aerospace

final class RequestFolderTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let folder = RequestFolder()
        XCTAssertEqual(folder.name, "New Folder")
        XCTAssertNil(folder.parentID)
        XCTAssertEqual(folder.sortIndex, 0)

        let parent = UUID()
        let original = RequestFolder(name: "Auth", parentID: parent, sortIndex: 3)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RequestFolder.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.parentID, parent)
    }
}
