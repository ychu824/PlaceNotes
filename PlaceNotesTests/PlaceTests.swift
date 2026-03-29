import XCTest
import CoreLocation
@testable import PlaceNotes

final class PlaceTests: XCTestCase {

    // MARK: - Initialization

    func testInitSetsProperties() {
        let place = Place(name: "Test Cafe", latitude: 37.78, longitude: -122.41, category: "Cafe")
        XCTAssertEqual(place.name, "Test Cafe")
        XCTAssertEqual(place.latitude, 37.78)
        XCTAssertEqual(place.longitude, -122.41)
        XCTAssertEqual(place.category, "Cafe")
        XCTAssertTrue(place.visits.isEmpty)
    }

    func testInitCategoryDefaultsToNil() {
        let place = Place(name: "Unknown", latitude: 0, longitude: 0)
        XCTAssertNil(place.category)
    }

    // MARK: - Coordinate

    func testCoordinate() {
        let place = Place(name: "Test", latitude: 37.78, longitude: -122.41)
        let coord = place.coordinate
        XCTAssertEqual(coord.latitude, 37.78, accuracy: 0.001)
        XCTAssertEqual(coord.longitude, -122.41, accuracy: 0.001)
    }

    // MARK: - Qualified Stays

    func testQualifiedStaysFiltersCorrectly() {
        let place = Place(name: "Gym", latitude: 37.78, longitude: -122.41, category: "Gym")
        let now = Date()

        // 5 min visit — below threshold of 10
        let shortVisit = Visit(arrivalDate: now, departureDate: now.addingTimeInterval(5 * 60), place: place)
        // 30 min visit — above threshold
        let longVisit = Visit(arrivalDate: now, departureDate: now.addingTimeInterval(30 * 60), place: place)
        // 10 min visit — exactly at threshold
        let exactVisit = Visit(arrivalDate: now, departureDate: now.addingTimeInterval(10 * 60), place: place)

        place.visits = [shortVisit, longVisit, exactVisit]

        let qualified = place.qualifiedStays(minMinutes: 10)
        XCTAssertEqual(qualified.count, 2)
    }

    func testQualifiedStayCount() {
        let place = Place(name: "Cafe", latitude: 37.78, longitude: -122.41)
        let now = Date()

        place.visits = [
            Visit(arrivalDate: now, departureDate: now.addingTimeInterval(15 * 60), place: place),
            Visit(arrivalDate: now, departureDate: now.addingTimeInterval(3 * 60), place: place),
            Visit(arrivalDate: now, departureDate: now.addingTimeInterval(60 * 60), place: place),
        ]

        XCTAssertEqual(place.qualifiedStayCount(minMinutes: 10), 2)
        XCTAssertEqual(place.qualifiedStayCount(minMinutes: 1), 3)
        XCTAssertEqual(place.qualifiedStayCount(minMinutes: 120), 0)
    }

    func testTotalQualifiedMinutes() {
        let place = Place(name: "Library", latitude: 37.78, longitude: -122.41)
        let now = Date()

        place.visits = [
            Visit(arrivalDate: now, departureDate: now.addingTimeInterval(20 * 60), place: place), // 20 min
            Visit(arrivalDate: now, departureDate: now.addingTimeInterval(5 * 60), place: place),  // 5 min
            Visit(arrivalDate: now, departureDate: now.addingTimeInterval(45 * 60), place: place), // 45 min
        ]

        // min 10: only 20 + 45 = 65
        XCTAssertEqual(place.totalQualifiedMinutes(minMinutes: 10), 65)
    }

    // MARK: - Total Tracked Minutes

    func testTotalTrackedMinutesEmpty() {
        let place = Place(name: "Empty", latitude: 0, longitude: 0)
        XCTAssertEqual(place.totalTrackedMinutes, 0)
    }

    func testTotalTrackedMinutesSumsAll() {
        let place = Place(name: "Office", latitude: 37.78, longitude: -122.41)
        let now = Date()

        place.visits = [
            Visit(arrivalDate: now, departureDate: now.addingTimeInterval(10 * 60), place: place),
            Visit(arrivalDate: now, departureDate: now.addingTimeInterval(20 * 60), place: place),
        ]

        XCTAssertEqual(place.totalTrackedMinutes, 30)
    }
}
