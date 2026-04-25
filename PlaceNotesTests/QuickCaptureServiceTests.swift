import XCTest
import CoreLocation
import SwiftData
@testable import PlaceNotes

@MainActor
final class QuickCaptureServiceTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Place.self, Visit.self, JournalEntry.self, CustomCategory.self, RawLocationSample.self,
            configurations: config
        )
        return ModelContext(container)
    }

    private func loc(lat: Double, lon: Double, accuracy: CLLocationAccuracy, age: TimeInterval = 0) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            timestamp: Date().addingTimeInterval(-age)
        )
    }

    // MARK: - Coordinate resolution priority (D1)

    func testLiveFixUsedWhenAccuracyIs50mOrBetter() {
        let live = loc(lat: 1, lon: 2, accuracy: 50)
        let exif = loc(lat: 9, lon: 9, accuracy: 10)
        let pick = QuickCaptureService.resolveCoordinate(liveFix: live, exifLocation: exif)
        XCTAssertEqual(pick?.coordinate.latitude, 1)
    }

    func testExifUsedWhenLiveFixTooCoarse() {
        let live = loc(lat: 1, lon: 2, accuracy: 80)
        let exif = loc(lat: 3, lon: 4, accuracy: 20)
        let pick = QuickCaptureService.resolveCoordinate(liveFix: live, exifLocation: exif)
        XCTAssertEqual(pick?.coordinate.latitude, 3)
    }

    func testReturnsNilWhenBothUnusable() {
        let live = loc(lat: 1, lon: 2, accuracy: 200)
        let pick = QuickCaptureService.resolveCoordinate(liveFix: live, exifLocation: nil)
        XCTAssertNil(pick)
    }

    func testExifUsedWhenLiveFixIsNil() {
        let exif = loc(lat: 3, lon: 4, accuracy: 20)
        let pick = QuickCaptureService.resolveCoordinate(liveFix: nil, exifLocation: exif)
        XCTAssertEqual(pick?.coordinate.latitude, 3)
    }

    // MARK: - Merge decision (D5)

    func testMergesWithActiveVisitAtSamePlace() throws {
        let ctx = try makeContext()
        let home = Place(name: "Home", latitude: 37.78, longitude: -122.41)
        ctx.insert(home)
        let active = Visit(arrivalDate: Date().addingTimeInterval(-120), departureDate: nil, place: home)
        ctx.insert(active)
        try ctx.save()

        let decision = QuickCaptureService.mergeDecision(for: home, now: Date())
        XCTAssertEqual(decision, .mergeWith(visitID: active.id))
    }

    func testMergesWithVisitEndedWithin30Min() throws {
        let ctx = try makeContext()
        let home = Place(name: "Home", latitude: 37.78, longitude: -122.41)
        ctx.insert(home)
        let now = Date()
        let recent = Visit(
            arrivalDate: now.addingTimeInterval(-3600),
            departureDate: now.addingTimeInterval(-600),
            place: home
        )
        ctx.insert(recent)
        try ctx.save()

        let decision = QuickCaptureService.mergeDecision(for: home, now: now)
        XCTAssertEqual(decision, .mergeWith(visitID: recent.id))
    }

    func testDoesNotMergeWithOldVisit() throws {
        let ctx = try makeContext()
        let home = Place(name: "Home", latitude: 37.78, longitude: -122.41)
        ctx.insert(home)
        let now = Date()
        let old = Visit(
            arrivalDate: now.addingTimeInterval(-7200),
            departureDate: now.addingTimeInterval(-3600),
            place: home
        )
        ctx.insert(old)
        try ctx.save()

        let decision = QuickCaptureService.mergeDecision(for: home, now: now)
        XCTAssertEqual(decision, .createNew)
    }

    func testCreatesNewWhenNoVisitsAtPlace() throws {
        let ctx = try makeContext()
        let home = Place(name: "Home", latitude: 37.78, longitude: -122.41)
        ctx.insert(home)
        try ctx.save()

        let decision = QuickCaptureService.mergeDecision(for: home, now: Date())
        XCTAssertEqual(decision, .createNew)
    }

    // MARK: - logCapture pipeline

    func testLogCaptureCreatesVisitAndJournalWhenNoMergeCandidate() async throws {
        let ctx = try makeContext()
        let coord = CLLocationCoordinate2D(latitude: 37.78, longitude: -122.41)
        let place = Place(name: "Test Place", latitude: 37.78, longitude: -122.41)
        ctx.insert(place)
        try ctx.save()

        let result = await QuickCaptureService.logCapture(
            coordinate: CLLocation(latitude: coord.latitude, longitude: coord.longitude),
            photoAssetId: "asset-123",
            now: Date(),
            in: ctx
        )

        guard case let .newVisit(visitID, placeName, journalEntryID) = result else {
            return XCTFail("expected .newVisit, got \(result)")
        }
        XCTAssertEqual(placeName, "Test Place")

        let visits = try ctx.fetch(FetchDescriptor<Visit>())
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?.id, visitID)
        XCTAssertNotNil(visits.first?.departureDate)
        XCTAssertEqual(visits.first?.durationMinutes, 1)

        let entries = try ctx.fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, journalEntryID)
        XCTAssertEqual(entries.first?.photoAssetIdentifiers, ["asset-123"])
        XCTAssertEqual(entries.first?.place?.id, place.id)
    }

    func testLogCaptureMergesIntoActiveVisit() async throws {
        let ctx = try makeContext()
        let place = Place(name: "Home", latitude: 37.78, longitude: -122.41)
        ctx.insert(place)
        let active = Visit(arrivalDate: Date().addingTimeInterval(-120), departureDate: nil, place: place)
        ctx.insert(active)
        try ctx.save()

        let result = await QuickCaptureService.logCapture(
            coordinate: CLLocation(latitude: 37.78, longitude: -122.41),
            photoAssetId: "asset-456",
            now: Date(),
            in: ctx
        )

        guard case let .merged(intoVisitID, _, journalEntryID) = result else {
            return XCTFail("expected .merged, got \(result)")
        }
        XCTAssertEqual(intoVisitID, active.id)

        let visits = try ctx.fetch(FetchDescriptor<Visit>())
        XCTAssertEqual(visits.count, 1)
        let entries = try ctx.fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, journalEntryID)
        XCTAssertEqual(entries.first?.photoAssetIdentifiers, ["asset-456"])
    }
}
