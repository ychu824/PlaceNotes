import XCTest
@testable import PlaceNotes

final class VisitTests: XCTestCase {

    // MARK: - Duration

    func testDurationWithDeparture() {
        let arrival = Date()
        let departure = arrival.addingTimeInterval(90 * 60) // 90 minutes
        let visit = Visit(arrivalDate: arrival, departureDate: departure)
        XCTAssertEqual(visit.durationMinutes, 90)
    }

    func testDurationWithoutDepartureUsesNow() {
        let arrival = Date().addingTimeInterval(-30 * 60) // 30 minutes ago
        let visit = Visit(arrivalDate: arrival, departureDate: nil)
        // Should be approximately 30 minutes (allow 1 min tolerance for test execution)
        XCTAssertGreaterThanOrEqual(visit.durationMinutes, 29)
        XCTAssertLessThanOrEqual(visit.durationMinutes, 31)
    }

    func testDurationNeverNegative() {
        let arrival = Date().addingTimeInterval(60 * 60) // 1 hour in the future
        let departure = Date() // now
        let visit = Visit(arrivalDate: arrival, departureDate: departure)
        XCTAssertEqual(visit.durationMinutes, 0)
    }

    // MARK: - Time of Day

    func testTimeOfDayMorning() {
        let visit = makeVisit(hour: 8)
        XCTAssertEqual(visit.timeOfDay, .morning)
    }

    func testTimeOfDayAfternoon() {
        let visit = makeVisit(hour: 14)
        XCTAssertEqual(visit.timeOfDay, .afternoon)
    }

    func testTimeOfDayEvening() {
        let visit = makeVisit(hour: 19)
        XCTAssertEqual(visit.timeOfDay, .evening)
    }

    func testTimeOfDayNight() {
        let visit = makeVisit(hour: 23)
        XCTAssertEqual(visit.timeOfDay, .night)
    }

    func testTimeOfDayEarlyMorningIsNight() {
        let visit = makeVisit(hour: 3)
        XCTAssertEqual(visit.timeOfDay, .night)
    }

    func testTimeOfDayBoundaryMorningStart() {
        let visit = makeVisit(hour: 5)
        XCTAssertEqual(visit.timeOfDay, .morning)
    }

    func testTimeOfDayBoundaryAfternoonStart() {
        let visit = makeVisit(hour: 12)
        XCTAssertEqual(visit.timeOfDay, .afternoon)
    }

    func testTimeOfDayBoundaryEveningStart() {
        let visit = makeVisit(hour: 17)
        XCTAssertEqual(visit.timeOfDay, .evening)
    }

    func testTimeOfDayBoundaryNightStart() {
        let visit = makeVisit(hour: 21)
        XCTAssertEqual(visit.timeOfDay, .night)
    }

    // MARK: - Active State

    func testIsActiveWhenNoDeparture() {
        let visit = Visit(arrivalDate: Date(), departureDate: nil)
        XCTAssertTrue(visit.isActive)
    }

    func testNotActiveWhenDepartureSet() {
        let visit = Visit(arrivalDate: Date(), departureDate: Date())
        XCTAssertFalse(visit.isActive)
    }

    // MARK: - Helpers

    private func makeVisit(hour: Int) -> Visit {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = 30
        let date = Calendar.current.date(from: components)!
        return Visit(arrivalDate: date, departureDate: date.addingTimeInterval(3600))
    }
}
