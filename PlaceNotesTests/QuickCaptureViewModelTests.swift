import XCTest
import CoreLocation
import SwiftData
@testable import PlaceNotes

@MainActor
final class QuickCaptureViewModelTests: XCTestCase {

    @MainActor
    private final class StubOneShot: LocationOneShotProviding {
        var result: CLLocation?
        func fetchOnce(timeout: TimeInterval) async -> CLLocation? { result }
        func cancel() {}
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Place.self, Visit.self, JournalEntry.self, CustomCategory.self, RawLocationSample.self,
            configurations: config
        )
        return ModelContext(container)
    }

    func testInitialStateIsIdle() throws {
        let vm = QuickCaptureViewModel(oneShot: StubOneShot(), context: try makeContext())
        XCTAssertEqual(vm.state, .idle)
    }

    func testBeginCaptureMovesToAcquiringLocation() async throws {
        let stub = StubOneShot()
        stub.result = CLLocation(latitude: 37.78, longitude: -122.41)
        let vm = QuickCaptureViewModel(oneShot: stub, context: try makeContext())
        vm.beginCapture()
        XCTAssertEqual(vm.state, .acquiringLocation)
    }

    func testCancelCaptureReturnsToIdle() throws {
        let vm = QuickCaptureViewModel(oneShot: StubOneShot(), context: try makeContext())
        vm.beginCapture()
        vm.cancelCapture()
        XCTAssertEqual(vm.state, .idle)
    }
}
