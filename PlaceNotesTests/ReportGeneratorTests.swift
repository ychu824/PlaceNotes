import XCTest
@testable import PlaceNotes

final class ReportGeneratorTests: XCTestCase {

    // MARK: - Frequent Places

    func testFrequentPlacesFiltersShortVisits() {
        let place = makePlaceWithVisits(name: "Cafe", durations: [5, 15, 25])
        let rankings = ReportGenerator.frequentPlaces(
            from: [place],
            since: Date().addingTimeInterval(-86400),
            minStayMinutes: 10
        )
        XCTAssertEqual(rankings.count, 1)
        XCTAssertEqual(rankings.first?.qualifiedStays, 2) // 15 + 25, not the 5 min one
        XCTAssertEqual(rankings.first?.totalMinutes, 40) // 15 + 25
    }

    func testFrequentPlacesExcludesPlaceWithNoQualifiedVisits() {
        let place = makePlaceWithVisits(name: "Quick Stop", durations: [1, 2, 3])
        let rankings = ReportGenerator.frequentPlaces(
            from: [place],
            since: Date().addingTimeInterval(-86400),
            minStayMinutes: 10
        )
        XCTAssertTrue(rankings.isEmpty)
    }

    func testFrequentPlacesSortsByStaysThenMinutes() {
        let cafeVisits = makePlaceWithVisits(name: "Cafe", durations: [30, 30, 30]) // 3 stays, 90 min
        let gymVisits = makePlaceWithVisits(name: "Gym", durations: [60, 60]) // 2 stays, 120 min
        let libVisits = makePlaceWithVisits(name: "Library", durations: [20, 20]) // 2 stays, 40 min

        let rankings = ReportGenerator.frequentPlaces(
            from: [gymVisits, cafeVisits, libVisits],
            since: Date().addingTimeInterval(-86400),
            minStayMinutes: 10
        )

        XCTAssertEqual(rankings.count, 3)
        XCTAssertEqual(rankings[0].place.name, "Cafe") // 3 stays wins
        XCTAssertEqual(rankings[1].place.name, "Gym") // 2 stays, 120 min > 40 min
        XCTAssertEqual(rankings[2].place.name, "Library")
    }

    func testFrequentPlacesFiltersByDate() {
        let place = Place(name: "Office", latitude: 37.78, longitude: -122.41)
        let now = Date()

        // Visit from 2 days ago
        let oldVisit = Visit(
            arrivalDate: now.addingTimeInterval(-2 * 86400),
            departureDate: now.addingTimeInterval(-2 * 86400 + 3600),
            place: place
        )
        // Visit from today
        let recentVisit = Visit(
            arrivalDate: now.addingTimeInterval(-3600),
            departureDate: now,
            place: place
        )
        place.visits = [oldVisit, recentVisit]

        // Only look at last 24 hours
        let rankings = ReportGenerator.frequentPlaces(
            from: [place],
            since: now.addingTimeInterval(-86400),
            minStayMinutes: 10
        )
        XCTAssertEqual(rankings.count, 1)
        XCTAssertEqual(rankings.first?.qualifiedStays, 1)
    }

    func testFrequentPlacesReturnsEmptyForNoPlaces() {
        let rankings = ReportGenerator.frequentPlaces(
            from: [],
            since: Date().addingTimeInterval(-86400),
            minStayMinutes: 10
        )
        XCTAssertTrue(rankings.isEmpty)
    }

    // MARK: - Monthly Report

    func testMonthlyReportGeneration() {
        let place = makePlaceWithVisits(name: "Office", durations: [60, 120, 30])
        let referenceDate = Date()

        let report = ReportGenerator.generateMonthlyReport(
            places: [place],
            minStayMinutes: 10,
            referenceDate: referenceDate
        )

        XCTAssertFalse(report.month.isEmpty)
        XCTAssertEqual(report.totalVisits, 3)
        XCTAssertEqual(report.totalTrackedMinutes, 210) // 60 + 120 + 30
        XCTAssertEqual(report.topPlaces.count, 1)
    }

    func testMonthlyReportCapsAt10Places() {
        var places: [Place] = []
        for i in 0..<15 {
            places.append(makePlaceWithVisits(name: "Place \(i)", durations: [30]))
        }

        let report = ReportGenerator.generateMonthlyReport(
            places: places,
            minStayMinutes: 10
        )

        XCTAssertLessThanOrEqual(report.topPlaces.count, 10)
    }

    func testMonthlyReportTimeOfDay() {
        let place = Place(name: "Work", latitude: 37.78, longitude: -122.41)
        let now = Date()

        // Create morning visits
        for _ in 0..<5 {
            var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
            components.hour = 9
            let arrival = Calendar.current.date(from: components)!
            place.visits.append(
                Visit(arrivalDate: arrival, departureDate: arrival.addingTimeInterval(3600), place: place)
            )
        }
        // Create 1 evening visit
        var eveningComponents = Calendar.current.dateComponents([.year, .month, .day], from: now)
        eveningComponents.hour = 19
        let eveningArrival = Calendar.current.date(from: eveningComponents)!
        place.visits.append(
            Visit(arrivalDate: eveningArrival, departureDate: eveningArrival.addingTimeInterval(3600), place: place)
        )

        let report = ReportGenerator.generateMonthlyReport(places: [place], minStayMinutes: 10)
        XCTAssertEqual(report.preferredTimeOfDay, .morning)
    }

    func testMonthlyReportEmptyPlaces() {
        let report = ReportGenerator.generateMonthlyReport(places: [], minStayMinutes: 10)
        XCTAssertEqual(report.totalVisits, 0)
        XCTAssertEqual(report.totalTrackedMinutes, 0)
        XCTAssertTrue(report.topPlaces.isEmpty)
    }

    // MARK: - Helpers

    private func makePlaceWithVisits(name: String, durations: [Int]) -> Place {
        let place = Place(name: name, latitude: 37.78, longitude: -122.41)
        let now = Date()
        for (index, duration) in durations.enumerated() {
            let arrival = now.addingTimeInterval(Double(-index) * 3600) // space them 1 hour apart
            let departure = arrival.addingTimeInterval(Double(duration) * 60)
            let visit = Visit(arrivalDate: arrival, departureDate: departure, place: place)
            place.visits.append(visit)
        }
        return place
    }
}
