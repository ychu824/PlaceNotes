import XCTest
@testable import PlaceNotes

final class TimeOfDayTests: XCTestCase {

    func testAllCasesCount() {
        XCTAssertEqual(TimeOfDay.allCases.count, 4)
    }

    func testRawValues() {
        XCTAssertEqual(TimeOfDay.morning.rawValue, "Morning")
        XCTAssertEqual(TimeOfDay.afternoon.rawValue, "Afternoon")
        XCTAssertEqual(TimeOfDay.evening.rawValue, "Evening")
        XCTAssertEqual(TimeOfDay.night.rawValue, "Night")
    }

    func testCodable() throws {
        for timeOfDay in TimeOfDay.allCases {
            let data = try JSONEncoder().encode(timeOfDay)
            let decoded = try JSONDecoder().decode(TimeOfDay.self, from: data)
            XCTAssertEqual(decoded, timeOfDay)
        }
    }
}
