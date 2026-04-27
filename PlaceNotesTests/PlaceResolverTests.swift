import XCTest
import SwiftData
import CoreLocation
@testable import PlaceNotes

@MainActor
final class PlaceResolverTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Place.self, Visit.self, JournalEntry.self, CustomCategory.self, RawLocationSample.self,
            configurations: config
        )
        return ModelContext(container)
    }

    func testNearestReturnsExistingPlaceWithin50m() throws {
        let ctx = try makeContext()
        let home = Place(name: "Home", latitude: 37.7800, longitude: -122.4100)
        ctx.insert(home)
        try ctx.save()

        let match = PlaceResolver.nearestExisting(
            latitude: 37.7803,
            longitude: -122.4100,
            in: ctx
        )
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.name, "Home")
    }

    func testNearestReturnsNilBeyond50m() throws {
        let ctx = try makeContext()
        let home = Place(name: "Home", latitude: 37.7800, longitude: -122.4100)
        ctx.insert(home)
        try ctx.save()

        let match = PlaceResolver.nearestExisting(
            latitude: 37.7810,
            longitude: -122.4100,
            in: ctx
        )
        XCTAssertNil(match)
    }
}
