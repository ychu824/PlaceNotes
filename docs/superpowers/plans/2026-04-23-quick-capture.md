# Quick-Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a shutter-button-as-hero on the first tab that captures a photo and logs a Visit at the user's current place, with EXIF fallback and merge-with-existing-visit behavior.

**Architecture:** A new `QuickCaptureService` orchestrates a one-shot `CLLocationManager` fix, camera + `PHPhotoLibrary` save, place resolution via an extracted `PlaceResolver`, and a merge decision over existing Visits. The first-tab view is rewritten so the shutter dominates and tracking controls collapse to a chip + sheet. All SwiftData mutations stay on `@MainActor`, consistent with the existing pattern.

**Tech Stack:** SwiftUI, SwiftData, CoreLocation, Photos (PhotoKit), AVFoundation, XCTest.

**Spec:** `docs/superpowers/specs/2026-04-23-quick-capture-design.md`

**Build & test commands:**
- Regenerate project: `xcodegen generate`
- Run tests: `xcodebuild test -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -quiet`

---

## File Structure

**Create:**
- `PlaceNotes/Services/PlaceResolver.swift` — extracted from `LocationManager`
- `PlaceNotes/Services/LocationOneShot.swift` — one-shot GPS helper + protocol
- `PlaceNotes/Services/QuickCaptureService.swift` — orchestrator
- `PlaceNotes/ViewModels/QuickCaptureViewModel.swift` — UI state machine
- `PlaceNotes/Views/CameraPickerView.swift` — UIViewControllerRepresentable over `UIImagePickerController`
- `PlaceNotes/Views/ManualPlacePickerView.swift` — fallback picker
- `PlaceNotes/Views/QuickCaptureToast.swift` — toast + undo/split actions
- `PlaceNotesTests/PlaceResolverTests.swift`
- `PlaceNotesTests/QuickCaptureServiceTests.swift`
- `PlaceNotesTests/QuickCaptureViewModelTests.swift`

**Modify:**
- `PlaceNotes/Services/LocationManager.swift` — replace private `findOrCreatePlace` / `resolvePlace` / `searchNearbyPOI` / `reverseGeocodeDetails` bodies with `PlaceResolver` calls at lines 203 and 407
- `PlaceNotes/Views/TrackingControlView.swift` — rewrite with shutter hero + tracking chip
- `PlaceNotes/PlaceNotesApp.swift` — instantiate `QuickCaptureService` + `QuickCaptureViewModel` and inject
- `PlaceNotes/Info.plist` — add camera + photos-add-only usage descriptions

---

## Task 1: Extract PlaceResolver (pure refactor)

**Files:**
- Create: `PlaceNotes/Services/PlaceResolver.swift`
- Modify: `PlaceNotes/Services/LocationManager.swift:203,407,483-649`
- Test: `PlaceNotesTests/PlaceResolverTests.swift`

Lifts `findOrCreatePlace`, `resolvePlace`, `searchNearbyPOI`, `reverseGeocodeDetails`, the private `ResolvedPlace` struct and the `GeoDetails` struct out of `LocationManager` into a standalone `enum PlaceResolver` with static methods. `LocationManager` becomes a caller. No behavioral change.

- [ ] **Step 1: Write a failing test for nearest-existing-place reuse**

Create `PlaceNotesTests/PlaceResolverTests.swift`:

```swift
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

        // ~30m north of home (0.0003 degrees latitude ≈ 33m)
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

        // ~110m north (0.001 degrees latitude)
        let match = PlaceResolver.nearestExisting(
            latitude: 37.7810,
            longitude: -122.4100,
            in: ctx
        )
        XCTAssertNil(match)
    }
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `xcodebuild test -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PlaceNotesTests/PlaceResolverTests -quiet`
Expected: FAIL with "cannot find 'PlaceResolver' in scope".

- [ ] **Step 3: Create PlaceResolver with the lifted logic**

Create `PlaceNotes/Services/PlaceResolver.swift`:

```swift
import Foundation
import CoreLocation
import MapKit
import SwiftData
import os

private let logger = Logger(subsystem: "com.placenotes.app", category: "PlaceResolver")

struct ResolvedPlace {
    let name: String
    let category: String?
    let city: String?
    let state: String?
    let source: String
    var alternatives: [PlaceCandidate] = []
}

struct GeoDetails {
    let name: String
    let city: String?
    let state: String?
}

enum PlaceResolver {

    /// Returns the nearest Place within ~50m of the given coordinate, if any exists.
    @MainActor
    static func nearestExisting(latitude: Double, longitude: Double, in context: ModelContext) -> Place? {
        let threshold = 0.0005 // ~50m
        let minLat = latitude - threshold
        let maxLat = latitude + threshold
        let minLon = longitude - threshold
        let maxLon = longitude + threshold
        let descriptor = FetchDescriptor<Place>(
            predicate: #Predicate<Place> {
                $0.latitude >= minLat && $0.latitude <= maxLat &&
                $0.longitude >= minLon && $0.longitude <= maxLon
            }
        )
        return (try? context.fetch(descriptor))?.first
    }

    /// Full resolve: nearest-existing → geocode + POI search → create + insert new Place.
    @MainActor
    static func findOrCreate(
        latitude: Double,
        longitude: Double,
        in context: ModelContext,
        addressOnly: Bool = false
    ) async -> (place: Place, alternatives: [PlaceCandidate]) {
        if let existing = nearestExisting(latitude: latitude, longitude: longitude, in: context) {
            logger.debug("Found existing place: \(existing.name)")
            return (existing, [])
        }
        let resolved = await resolve(latitude: latitude, longitude: longitude, addressOnly: addressOnly)
        let place = Place(
            name: resolved.name,
            latitude: latitude,
            longitude: longitude,
            category: resolved.category,
            city: resolved.city,
            state: resolved.state
        )
        context.insert(place)
        logger.notice("Created new place: \(resolved.name) (source: \(resolved.source))")
        return (place, resolved.alternatives)
    }

    // MARK: - Private

    private static func resolve(latitude: Double, longitude: Double, addressOnly: Bool) async -> ResolvedPlace {
        let geoInfo = await reverseGeocodeDetails(latitude: latitude, longitude: longitude)
        if addressOnly {
            return ResolvedPlace(name: geoInfo.name, category: nil, city: geoInfo.city, state: geoInfo.state, source: "address-fallback")
        }
        if let poi = await searchNearbyPOI(latitude: latitude, longitude: longitude, geoInfo: geoInfo) {
            return ResolvedPlace(name: poi.name, category: poi.category, city: geoInfo.city, state: geoInfo.state, source: poi.source, alternatives: poi.alternatives)
        }
        let categoryResult = await PlaceCategorizer.categorize(latitude: latitude, longitude: longitude)
        return ResolvedPlace(name: geoInfo.name, category: categoryResult?.label, city: geoInfo.city, state: geoInfo.state, source: "geocoder")
    }

    private static func searchNearbyPOI(latitude: Double, longitude: Double, geoInfo: GeoDetails?) async -> ResolvedPlace? {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let targetLocation = CLLocation(latitude: latitude, longitude: longitude)
        let searchRadius: CLLocationDistance = 150

        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: searchRadius)
        request.pointOfInterestFilter = .includingAll
        let search = MKLocalSearch(request: request)

        do {
            let response = try await search.start()
            let candidates = response.mapItems
                .compactMap { item -> (item: MKMapItem, distance: CLLocationDistance, name: String)? in
                    guard let name = item.name, !name.isEmpty,
                          let itemLocation = item.placemark.location else { return nil }
                    let dist = itemLocation.distance(from: targetLocation)
                    guard dist <= searchRadius else { return nil }
                    return (item, dist, name)
                }
                .sorted { $0.distance < $1.distance }

            guard let best = candidates.first else { return nil }

            let category: String? = {
                if let poiCategory = best.item.pointOfInterestCategory,
                   let match = PlaceCategorizer.categoryMap.first(where: { $0.category == poiCategory }) {
                    return match.label
                }
                return nil
            }()

            let altGeoInfo = geoInfo ?? (await reverseGeocodeDetails(latitude: latitude, longitude: longitude))
            let alternatives: [PlaceCandidate] = Array(candidates.dropFirst().prefix(2)).map { candidate in
                let altCategory: String? = {
                    if let poiCat = candidate.item.pointOfInterestCategory,
                       let match = PlaceCategorizer.categoryMap.first(where: { $0.category == poiCat }) {
                        return match.label
                    }
                    return nil
                }()
                return PlaceCandidate(
                    name: candidate.name,
                    latitude: candidate.item.placemark.coordinate.latitude,
                    longitude: candidate.item.placemark.coordinate.longitude,
                    category: altCategory,
                    city: altGeoInfo.city,
                    state: altGeoInfo.state,
                    distanceMeters: candidate.distance
                )
            }

            return ResolvedPlace(name: best.name, category: category, city: nil, state: nil, source: "mapkit", alternatives: alternatives)
        } catch {
            logger.warning("MKLocalSearch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func reverseGeocodeDetails(latitude: Double, longitude: Double) async -> GeoDetails {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                let name = placemark.name
                    ?? placemark.thoroughfare
                    ?? placemark.subLocality
                    ?? placemark.locality
                    ?? "Unknown Place"
                return GeoDetails(name: name, city: placemark.locality, state: placemark.administrativeArea)
            }
        } catch {
            logger.error("Geocoding failed: \(error.localizedDescription)")
        }
        return GeoDetails(name: "Unknown Place", city: nil, state: nil)
    }
}
```

- [ ] **Step 4: Remove the lifted code from LocationManager and delegate to PlaceResolver**

In `PlaceNotes/Services/LocationManager.swift`:

- Delete lines 480–649 (the private `findOrCreatePlace`, `resolvePlace`, `searchNearbyPOI`, `reverseGeocodeDetails`, `ResolvedPlace`, `GeoDetails`).
- Replace the call at line 203 `let (place, alternatives) = await findOrCreatePlace(latitude: ..., longitude: ..., in: context, addressOnly: ...)` with `let (place, alternatives) = await PlaceResolver.findOrCreate(latitude: ..., longitude: ..., in: context, addressOnly: ...)`.
- Do the same replacement at line 407.
- Remove the unused `import MapKit` from `LocationManager.swift` **only if** no other code in that file references MapKit after the extraction.

- [ ] **Step 5: Regenerate project and run all tests**

```bash
xcodegen generate
xcodebuild test -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -quiet
```

Expected: All existing tests pass + new `PlaceResolverTests` pass.

- [ ] **Step 6: Commit**

```bash
git add PlaceNotes/Services/PlaceResolver.swift PlaceNotes/Services/LocationManager.swift PlaceNotesTests/PlaceResolverTests.swift project.pbxproj
git commit -m "refactor: extract PlaceResolver from LocationManager"
```

---

## Task 2: LocationOneShot helper

**Files:**
- Create: `PlaceNotes/Services/LocationOneShot.swift`

No unit tests — this is a thin adapter over `CLLocationManager.requestLocation()` and testing it would mostly mock Apple's SDK. The protocol defined here is what downstream tests will mock.

- [ ] **Step 1: Write the LocationOneShot protocol and implementation**

Create `PlaceNotes/Services/LocationOneShot.swift`:

```swift
import Foundation
import CoreLocation
import os

private let logger = Logger(subsystem: "com.placenotes.app", category: "LocationOneShot")

protocol LocationOneShotProviding {
    func fetchOnce(timeout: TimeInterval) async -> CLLocation?
}

/// Wraps CLLocationManager.requestLocation() as an async call.
/// Returns nil on timeout, permission denial, or CL error — callers fall back.
final class LocationOneShot: NSObject, LocationOneShotProviding, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func fetchOnce(timeout: TimeInterval) async -> CLLocation? {
        // Guard: don't pile up concurrent requests.
        if continuation != nil {
            logger.warning("fetchOnce called while a previous request is still pending")
            return nil
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            self.continuation = cont
            self.manager.requestLocation()
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.resume(with: nil)
            }
        }
    }

    private func resume(with location: CLLocation?) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: location)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        resume(with: locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.warning("one-shot failed: \(error.localizedDescription)")
        resume(with: nil)
    }
}
```

- [ ] **Step 2: Build to verify the file compiles**

```bash
xcodegen generate
xcodebuild -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -quiet build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add PlaceNotes/Services/LocationOneShot.swift project.pbxproj
git commit -m "feat: add LocationOneShot helper for single GPS fix"
```

---

## Task 3: QuickCaptureService — merge decision logic (TDD core)

**Files:**
- Create: `PlaceNotes/Services/QuickCaptureService.swift`
- Test: `PlaceNotesTests/QuickCaptureServiceTests.swift`

This is the biggest task. We TDD the pure merge-decision logic first (no photo, no camera, no real location), then wire it to the photo pipeline in a later step.

The service exposes two entry points:
- `resolveCoordinate(liveFix:exifLocation:) -> CLLocation?` — pure function, picks per D1 priority.
- `logCapture(coordinate:photoAssetId:modelContext:) async -> QuickCaptureResult` — runs the full pipeline.

`QuickCaptureResult` tells the UI what toast to show:
```swift
enum QuickCaptureResult {
    case newVisit(visitID: UUID, placeName: String, journalEntryID: UUID)
    case merged(intoVisitID: UUID, placeName: String, journalEntryID: UUID)
}
```

- [ ] **Step 1: Write the failing test for coordinate resolution priority**

Create `PlaceNotesTests/QuickCaptureServiceTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `xcodebuild test -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PlaceNotesTests/QuickCaptureServiceTests -quiet`
Expected: FAIL with "cannot find 'QuickCaptureService' in scope".

- [ ] **Step 3: Create QuickCaptureService with resolveCoordinate**

Create `PlaceNotes/Services/QuickCaptureService.swift`:

```swift
import Foundation
import CoreLocation
import SwiftData
import os

private let logger = Logger(subsystem: "com.placenotes.app", category: "QuickCaptureService")

enum QuickCaptureResult {
    case newVisit(visitID: UUID, placeName: String, journalEntryID: UUID)
    case merged(intoVisitID: UUID, placeName: String, journalEntryID: UUID)
}

enum QuickCaptureError: Error {
    case noLocation
    case placeNotResolved
}

enum QuickCaptureService {

    /// Max accuracy (meters) to trust a live GPS fix. Beyond this, fall through to EXIF.
    /// Matches the 50m nearest-place radius in PlaceResolver — if accuracy exceeds the
    /// matching radius, a "nearest" lookup could mis-attribute across neighbors.
    static let liveFixAccuracyThreshold: CLLocationDistance = 50

    /// Resolves the coordinate for a quick capture per D1 priority:
    /// 1. live fix if accuracy ≤ 50m
    /// 2. EXIF location from the saved PHAsset
    /// 3. nil (caller opens ManualPlacePickerView)
    static func resolveCoordinate(liveFix: CLLocation?, exifLocation: CLLocation?) -> CLLocation? {
        if let live = liveFix,
           live.horizontalAccuracy >= 0,
           live.horizontalAccuracy <= liveFixAccuracyThreshold {
            return live
        }
        return exifLocation
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `xcodebuild test -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PlaceNotesTests/QuickCaptureServiceTests -quiet`
Expected: 4 tests pass.

- [ ] **Step 5: Write failing tests for merge-decision logic**

Append to `PlaceNotesTests/QuickCaptureServiceTests.swift` (inside the class):

```swift
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
            departureDate: now.addingTimeInterval(-600), // 10 min ago
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
            departureDate: now.addingTimeInterval(-3600), // 60 min ago
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
```

- [ ] **Step 6: Run tests, verify they fail**

Run: `xcodebuild test -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PlaceNotesTests/QuickCaptureServiceTests -quiet`
Expected: FAIL with "type 'QuickCaptureService' has no member 'mergeDecision'".

- [ ] **Step 7: Add mergeDecision to QuickCaptureService**

Append to `PlaceNotes/Services/QuickCaptureService.swift`:

```swift
extension QuickCaptureService {

    /// Window after a visit's departure during which a capture still merges into it.
    static let mergeWindow: TimeInterval = 30 * 60

    enum MergeDecision: Equatable {
        case mergeWith(visitID: UUID)
        case createNew
    }

    /// Decides whether a new capture at `place` should merge into an existing Visit.
    /// Returns `.mergeWith` if there is an active visit, or a visit whose departure is within the merge window.
    static func mergeDecision(for place: Place, now: Date) -> MergeDecision {
        let cutoff = now.addingTimeInterval(-mergeWindow)
        let candidate = place.visits
            .filter { visit in
                if visit.departureDate == nil { return true }
                return (visit.departureDate ?? .distantPast) > cutoff
            }
            .sorted { $0.arrivalDate > $1.arrivalDate }
            .first
        if let c = candidate {
            return .mergeWith(visitID: c.id)
        }
        return .createNew
    }
}
```

- [ ] **Step 8: Run tests, verify they pass**

Run: `xcodebuild test -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PlaceNotesTests/QuickCaptureServiceTests -quiet`
Expected: 8 tests pass.

- [ ] **Step 9: Write failing test for end-to-end logCapture pipeline (new-visit path)**

Append to the test class:

```swift
    // MARK: - logCapture pipeline

    func testLogCaptureCreatesVisitAndJournalWhenNoMergeCandidate() async throws {
        let ctx = try makeContext()
        let coord = CLLocationCoordinate2D(latitude: 37.78, longitude: -122.41)
        // Pre-seed a Place so we don't need network/POI search.
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
        XCTAssertEqual(visits.count, 1) // no new visit
        let entries = try ctx.fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, journalEntryID)
        XCTAssertEqual(entries.first?.photoAssetIdentifiers, ["asset-456"])
    }
```

- [ ] **Step 10: Run tests, verify they fail**

Run: `xcodebuild test -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PlaceNotesTests/QuickCaptureServiceTests -quiet`
Expected: FAIL with "type 'QuickCaptureService' has no member 'logCapture'".

- [ ] **Step 11: Implement logCapture**

Append to `PlaceNotes/Services/QuickCaptureService.swift`:

```swift
extension QuickCaptureService {

    /// Duration of a non-merge quick-capture visit. See spec D6.
    static let quickVisitDuration: TimeInterval = 60

    /// End-to-end pipeline: resolves the Place (nearest-or-create), decides merge vs new,
    /// creates a JournalEntry carrying the photo, and creates a Visit if not merging.
    @MainActor
    static func logCapture(
        coordinate: CLLocation,
        photoAssetId: String,
        now: Date = Date(),
        in context: ModelContext
    ) async -> QuickCaptureResult {
        let (place, _) = await PlaceResolver.findOrCreate(
            latitude: coordinate.coordinate.latitude,
            longitude: coordinate.coordinate.longitude,
            in: context
        )

        let entry = JournalEntry(date: now, photoAssetIdentifiers: [photoAssetId])
        entry.place = place
        context.insert(entry)

        switch mergeDecision(for: place, now: now) {
        case .mergeWith(let visitID):
            try? context.save()
            return .merged(intoVisitID: visitID, placeName: place.displayName, journalEntryID: entry.id)

        case .createNew:
            let visit = Visit(
                arrivalDate: now,
                departureDate: now.addingTimeInterval(quickVisitDuration),
                place: place
            )
            visit.confidence = .high
            context.insert(visit)
            try? context.save()
            return .newVisit(visitID: visit.id, placeName: place.displayName, journalEntryID: entry.id)
        }
    }
}
```

- [ ] **Step 12: Run all tests, verify they pass**

Run: `xcodebuild test -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -quiet`
Expected: all tests pass, including 10 in `QuickCaptureServiceTests`.

- [ ] **Step 13: Commit**

```bash
git add PlaceNotes/Services/QuickCaptureService.swift PlaceNotesTests/QuickCaptureServiceTests.swift project.pbxproj
git commit -m "feat: add QuickCaptureService with merge decision and logCapture"
```

---

## Task 4: QuickCaptureViewModel — state machine

**Files:**
- Create: `PlaceNotes/ViewModels/QuickCaptureViewModel.swift`
- Test: `PlaceNotesTests/QuickCaptureViewModelTests.swift`

- [ ] **Step 1: Write failing tests for state transitions**

Create `PlaceNotesTests/QuickCaptureViewModelTests.swift`:

```swift
import XCTest
import CoreLocation
import SwiftData
@testable import PlaceNotes

@MainActor
final class QuickCaptureViewModelTests: XCTestCase {

    private final class StubOneShot: LocationOneShotProviding {
        var result: CLLocation?
        func fetchOnce(timeout: TimeInterval) async -> CLLocation? { result }
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
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `xcodebuild test -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PlaceNotesTests/QuickCaptureViewModelTests -quiet`
Expected: FAIL — type not found.

- [ ] **Step 3: Implement QuickCaptureViewModel**

Create `PlaceNotes/ViewModels/QuickCaptureViewModel.swift`:

```swift
import Foundation
import CoreLocation
import Combine
import SwiftData
import Photos
import UIKit
import os

private let logger = Logger(subsystem: "com.placenotes.app", category: "QuickCaptureViewModel")

@MainActor
final class QuickCaptureViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case acquiringLocation
        case savingPhoto
        case resolvingPlace
        case manualPickNeeded        // UI opens ManualPlacePickerView
        case done(ToastPayload)
        case error(String)
    }

    struct ToastPayload: Equatable {
        enum Kind: Equatable { case newVisit, merged }
        let kind: Kind
        let placeName: String
        let visitID: UUID
        let journalEntryID: UUID
    }

    @Published private(set) var state: State = .idle
    @Published var showCamera: Bool = false

    private let oneShot: LocationOneShotProviding
    private let context: ModelContext
    private var pendingLiveFix: CLLocation?

    init(oneShot: LocationOneShotProviding, context: ModelContext) {
        self.oneShot = oneShot
        self.context = context
    }

    // MARK: - Flow

    func beginCapture() {
        guard state == .idle else { return }
        state = .acquiringLocation
        showCamera = true
        Task { [weak self] in
            guard let self else { return }
            let loc = await self.oneShot.fetchOnce(timeout: 5)
            await MainActor.run { self.pendingLiveFix = loc }
        }
    }

    /// Called by CameraPickerView when the user taps "Use Photo".
    func photoCaptured(image: UIImage, exifLocation: CLLocation?) {
        state = .savingPhoto
        Task { [weak self] in
            guard let self else { return }
            do {
                let assetId = try await self.savePhotoToLibrary(image: image)
                await self.continueAfterPhoto(photoAssetId: assetId, exifLocation: exifLocation)
            } catch {
                logger.error("photo save failed: \(error.localizedDescription)")
                await MainActor.run { self.state = .error("Couldn't save photo: \(error.localizedDescription)") }
            }
        }
    }

    func cancelCapture() {
        pendingLiveFix = nil
        showCamera = false
        state = .idle
    }

    /// Called when the user picks a Place manually after the automatic fallback.
    func manualPlaceSelected(_ place: Place, photoAssetId: String) {
        state = .resolvingPlace
        Task { [weak self] in
            guard let self else { return }
            let result = await QuickCaptureService.logCapture(
                coordinate: CLLocation(latitude: place.latitude, longitude: place.longitude),
                photoAssetId: photoAssetId,
                in: self.context
            )
            await MainActor.run { self.state = .done(self.toast(from: result)) }
        }
    }

    // Undo (new-visit path): delete the new Visit and JournalEntry.
    func undoNewVisit(_ payload: ToastPayload) {
        let entryDesc = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.id == payload.journalEntryID })
        let visitDesc = FetchDescriptor<Visit>(predicate: #Predicate { $0.id == payload.visitID })
        if let entry = (try? context.fetch(entryDesc))?.first { context.delete(entry) }
        if let visit = (try? context.fetch(visitDesc))?.first { context.delete(visit) }
        try? context.save()
        state = .idle
    }

    // Split (merge path): promote the journal entry into its own Visit at the same Place.
    func splitFromMerge(_ payload: ToastPayload) {
        let entryDesc = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.id == payload.journalEntryID })
        guard let entry = (try? context.fetch(entryDesc))?.first, let place = entry.place else {
            state = .idle
            return
        }
        let now = Date()
        let visit = Visit(
            arrivalDate: now,
            departureDate: now.addingTimeInterval(QuickCaptureService.quickVisitDuration),
            place: place
        )
        visit.confidence = .high
        context.insert(visit)
        try? context.save()
        state = .idle
    }

    // MARK: - Private

    private func continueAfterPhoto(photoAssetId: String, exifLocation: CLLocation?) async {
        let coord = QuickCaptureService.resolveCoordinate(liveFix: pendingLiveFix, exifLocation: exifLocation)
        guard let coord else {
            await MainActor.run { self.state = .manualPickNeeded }
            return
        }
        await MainActor.run { self.state = .resolvingPlace }
        let result = await QuickCaptureService.logCapture(
            coordinate: coord,
            photoAssetId: photoAssetId,
            in: context
        )
        await MainActor.run { self.state = .done(self.toast(from: result)) }
    }

    private func toast(from result: QuickCaptureResult) -> ToastPayload {
        switch result {
        case .newVisit(let vid, let name, let eid):
            return ToastPayload(kind: .newVisit, placeName: name, visitID: vid, journalEntryID: eid)
        case .merged(let vid, let name, let eid):
            return ToastPayload(kind: .merged, placeName: name, visitID: vid, journalEntryID: eid)
        }
    }

    private func savePhotoToLibrary(image: UIImage) async throws -> String {
        try await ensureAddOnlyPhotosPermission()
        var assetId: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
            assetId = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let id = assetId else { throw QuickCaptureError.placeNotResolved }
        return id
    }

    private func ensureAddOnlyPhotosPermission() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard newStatus == .authorized || newStatus == .limited else {
                throw QuickCaptureError.noLocation
            }
        case .denied, .restricted:
            throw QuickCaptureError.noLocation
        @unknown default:
            throw QuickCaptureError.noLocation
        }
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `xcodebuild test -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PlaceNotesTests/QuickCaptureViewModelTests -quiet`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add PlaceNotes/ViewModels/QuickCaptureViewModel.swift PlaceNotesTests/QuickCaptureViewModelTests.swift project.pbxproj
git commit -m "feat: add QuickCaptureViewModel state machine"
```

---

## Task 5: CameraPickerView (UIImagePickerController wrapper)

**Files:**
- Create: `PlaceNotes/Views/CameraPickerView.swift`

No unit test — this is a SwiftUI wrapper over a UIKit controller. Covered by manual smoke test in Task 9.

- [ ] **Step 1: Create CameraPickerView**

Create `PlaceNotes/Views/CameraPickerView.swift`:

```swift
import SwiftUI
import UIKit
import CoreLocation
import AVFoundation

struct CameraPickerView: UIViewControllerRepresentable {
    let onCaptured: (UIImage, CLLocation?) -> Void
    let onCancelled: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .rear
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerView
        init(parent: CameraPickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.onCancelled()
                return
            }
            // UIImagePickerController does not expose CLLocation directly for camera source.
            // Location will be resolved post-save via PHAsset.location.
            parent.onCaptured(image, nil)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancelled()
        }
    }

    /// Call before presenting — returns true if camera permission is granted.
    static func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodegen generate
xcodebuild -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -quiet build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add PlaceNotes/Views/CameraPickerView.swift project.pbxproj
git commit -m "feat: add CameraPickerView wrapper"
```

---

## Task 6: Resolve EXIF from saved PHAsset (bridge photo → coordinate)

**Files:**
- Modify: `PlaceNotes/ViewModels/QuickCaptureViewModel.swift`

`UIImagePickerController` doesn't hand us CLLocation for camera sources, and the image's `CGImageSource` EXIF is stripped from `UIImage.pngData()`. But once the image is saved to Photos, `PHAsset.location` gives us the embedded GPS (iOS fills it in at capture time). So we re-fetch the asset after save and read its location.

- [ ] **Step 1: Update savePhotoToLibrary to return (assetId, exifLocation)**

In `PlaceNotes/ViewModels/QuickCaptureViewModel.swift`, replace the `savePhotoToLibrary(image:)` method and update its caller:

```swift
    private struct SavedPhoto {
        let assetId: String
        let exifLocation: CLLocation?
    }

    private func savePhotoToLibrary(image: UIImage) async throws -> SavedPhoto {
        try await ensureAddOnlyPhotosPermission()
        var assetId: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
            assetId = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let id = assetId else { throw QuickCaptureError.placeNotResolved }

        // Fetch the asset back to read EXIF location (requires .readWrite or .addOnly with asset access).
        // PHAsset.location is populated by iOS when the camera captured the photo.
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        let exif = fetch.firstObject?.location
        return SavedPhoto(assetId: id, exifLocation: exif)
    }
```

Update `photoCaptured`:

```swift
    func photoCaptured(image: UIImage, exifLocation: CLLocation?) {
        state = .savingPhoto
        Task { [weak self] in
            guard let self else { return }
            do {
                let saved = try await self.savePhotoToLibrary(image: image)
                // Prefer picker-provided exifLocation if present (future-proofing), else PHAsset.location.
                let exif = exifLocation ?? saved.exifLocation
                await self.continueAfterPhoto(photoAssetId: saved.assetId, exifLocation: exif)
            } catch {
                logger.error("photo save failed: \(error.localizedDescription)")
                await MainActor.run { self.state = .error("Couldn't save photo: \(error.localizedDescription)") }
            }
        }
    }
```

- [ ] **Step 2: Build and run tests**

```bash
xcodebuild test -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -quiet
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add PlaceNotes/ViewModels/QuickCaptureViewModel.swift
git commit -m "feat: read EXIF location from saved PHAsset for fallback"
```

---

## Task 7: ManualPlacePickerView

**Files:**
- Create: `PlaceNotes/Views/ManualPlacePickerView.swift`

- [ ] **Step 1: Create ManualPlacePickerView**

Create `PlaceNotes/Views/ManualPlacePickerView.swift`:

```swift
import SwiftUI
import SwiftData
import MapKit

struct ManualPlacePickerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Place.name) private var allPlaces: [Place]

    let onPicked: (Place) -> Void
    let onCancelled: () -> Void

    @State private var search = ""
    @State private var droppedCoord: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            List {
                Section("Recent places") {
                    if filteredPlaces.isEmpty {
                        Text("No matching places")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredPlaces) { place in
                            Button {
                                onPicked(place)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(place.displayName)
                                    if let city = place.city {
                                        Text(city).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Pick a place")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancelled()
                        dismiss()
                    }
                }
            }
        }
    }

    private var filteredPlaces: [Place] {
        guard !search.isEmpty else { return Array(allPlaces.prefix(20)) }
        let needle = search.lowercased()
        return allPlaces.filter { $0.displayName.lowercased().contains(needle) }
    }
}
```

Note: "drop a map pin" is deferred — the existing places list + search covers 95% of the no-signal cases (user is at home / office / recent place). Adding a map-pin drop is a future enhancement if real usage demands it.

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -quiet build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add PlaceNotes/Views/ManualPlacePickerView.swift project.pbxproj
git commit -m "feat: add ManualPlacePickerView for no-signal fallback"
```

---

## Task 8: Info.plist permissions

**Files:**
- Modify: `PlaceNotes/Info.plist`

- [ ] **Step 1: Add NSCameraUsageDescription and NSPhotoLibraryAddUsageDescription**

Open `PlaceNotes/Info.plist`. Inside the top-level `<dict>`, add:

```xml
<key>NSCameraUsageDescription</key>
<string>PlaceNotes uses the camera to let you capture a photo and log the current place as a visit.</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>PlaceNotes saves captured photos to your library so they stay linked to the place you logged.</string>
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -quiet build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add PlaceNotes/Info.plist
git commit -m "chore: add camera + photos-add-only usage descriptions"
```

---

## Task 9: Rewrite TrackingControlView with shutter hero

**Files:**
- Create: `PlaceNotes/Views/QuickCaptureToast.swift`
- Modify: `PlaceNotes/Views/TrackingControlView.swift`

- [ ] **Step 1: Create QuickCaptureToast view**

Create `PlaceNotes/Views/QuickCaptureToast.swift`:

```swift
import SwiftUI

struct QuickCaptureToast: View {
    let payload: QuickCaptureViewModel.ToastPayload
    let onUndo: () -> Void       // new-visit path → delete
    let onSplit: () -> Void      // merged path → promote to own visit
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: payload.kind == .merged ? "link.badge.plus" : "checkmark.circle.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(payload.kind == .merged ? "Added to \(payload.placeName)" : "Logged at \(payload.placeName)")
                    .font(.subheadline.bold())
            }

            Spacer()

            Button(payload.kind == .merged ? "Split" : "Undo") {
                payload.kind == .merged ? onSplit() : onUndo()
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4, y: 2)
        .padding(.horizontal, 16)
        .onAppear {
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                onDismiss()
            }
        }
    }
}
```

- [ ] **Step 2: Rewrite TrackingControlView**

Overwrite `PlaceNotes/Views/TrackingControlView.swift`:

```swift
import SwiftUI

struct TrackingControlView: View {
    @EnvironmentObject var trackingViewModel: TrackingViewModel
    @EnvironmentObject var quickCapture: QuickCaptureViewModel

    @State private var showTrackingSheet = false
    @State private var showManualPicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 32) {
                    trackingChip
                        .padding(.top, 8)

                    Spacer()

                    shutterButton

                    Text("Tap to log this place")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding()

                if case let .done(payload) = quickCapture.state {
                    VStack {
                        Spacer()
                        QuickCaptureToast(
                            payload: payload,
                            onUndo: { quickCapture.undoNewVisit(payload) },
                            onSplit: { quickCapture.splitFromMerge(payload) },
                            onDismiss: { quickCapture.cancelCapture() }
                        )
                        .padding(.bottom, 24)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("PlaceNotes")
            .sheet(isPresented: $showTrackingSheet) { trackingSheet }
            .fullScreenCover(isPresented: $quickCapture.showCamera) {
                CameraPickerView(
                    onCaptured: { image, exif in
                        quickCapture.showCamera = false
                        quickCapture.photoCaptured(image: image, exifLocation: exif)
                    },
                    onCancelled: {
                        quickCapture.showCamera = false
                        quickCapture.cancelCapture()
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: Binding(
                get: { quickCapture.state == .manualPickNeeded },
                set: { newValue in
                    // Only cancel if we're still in the pick state (user dismissed the sheet).
                    // Don't cancel if the VM has already moved on (user picked a place).
                    if !newValue, quickCapture.state == .manualPickNeeded {
                        quickCapture.cancelCapture()
                    }
                }
            )) {
                // Note: requires threading the pending photoAssetId through VM.
                // For this MVP, ManualPlacePickerView asks VM for the pending id.
                ManualPlacePickerView(
                    onPicked: { place in
                        if let id = quickCapture.pendingPhotoAssetId {
                            quickCapture.manualPlaceSelected(place, photoAssetId: id)
                        }
                    },
                    onCancelled: { quickCapture.cancelCapture() }
                )
            }
            .alert("Capture failed", isPresented: Binding(
                get: { if case .error = quickCapture.state { return true } else { return false } },
                set: { if !$0 { quickCapture.cancelCapture() } }
            )) {
                Button("OK") { quickCapture.cancelCapture() }
            } message: {
                if case let .error(msg) = quickCapture.state { Text(msg) }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var trackingChip: some View {
        Button { showTrackingSheet = true } label: {
            HStack(spacing: 6) {
                Image(systemName: chipIcon).foregroundStyle(chipColor)
                Text(trackingViewModel.statusText).font(.footnote.weight(.medium))
                if let remaining = trackingViewModel.pauseTimeRemainingText {
                    Text("·").foregroundStyle(.secondary)
                    Text(remaining).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var shutterButton: some View {
        Button {
            Task {
                if await CameraPickerView.requestCameraPermission() {
                    quickCapture.beginCapture()
                } else {
                    // No permission — nothing happens; user can retry after granting in Settings.
                }
            }
        } label: {
            ZStack {
                Circle().fill(.white).frame(width: 96, height: 96)
                Circle().stroke(.primary, lineWidth: 4).frame(width: 112, height: 112)
            }
        }
        .disabled(quickCapture.state != .idle && quickCapture.state != .done(.init(kind: .newVisit, placeName: "", visitID: UUID(), journalEntryID: UUID())))
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var trackingSheet: some View {
        VStack(spacing: 16) {
            Text("Tracking")
                .font(.title2.bold())
                .padding(.top, 16)

            if trackingViewModel.trackingManager.state.status == .disabled {
                Button {
                    trackingViewModel.enable()
                    showTrackingSheet = false
                } label: {
                    Label("Enable Tracking", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if trackingViewModel.trackingManager.state.isPaused {
                Button {
                    trackingViewModel.resume()
                    showTrackingSheet = false
                } label: {
                    Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                VStack(spacing: 8) {
                    Text("Pause for…").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(PauseDuration.allCases, id: \.label) { duration in
                            Button(duration.label) {
                                trackingViewModel.pause(for: duration)
                                showTrackingSheet = false
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                Button(role: .destructive) {
                    trackingViewModel.disable()
                    showTrackingSheet = false
                } label: {
                    Label("Disable Tracking", systemImage: "location.slash.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding()
        .presentationDetents([.height(260)])
    }

    // MARK: - Chip styling

    private var chipIcon: String {
        switch trackingViewModel.trackingManager.state.status {
        case .active: return "location.fill"
        case .paused: return "pause.circle.fill"
        case .disabled: return "location.slash"
        }
    }

    private var chipColor: Color {
        switch trackingViewModel.trackingManager.state.status {
        case .active: return .green
        case .paused: return .orange
        case .disabled: return .secondary
        }
    }
}
```

- [ ] **Step 3: Add pendingPhotoAssetId to QuickCaptureViewModel**

The view references `quickCapture.pendingPhotoAssetId`, which we need to expose so `ManualPlacePickerView` can complete after the user picks.

In `PlaceNotes/ViewModels/QuickCaptureViewModel.swift`:

Add a stored property right under `@Published var showCamera`:

```swift
    @Published private(set) var pendingPhotoAssetId: String?
```

Update `continueAfterPhoto` to stash the id before returning `.manualPickNeeded`:

```swift
    private func continueAfterPhoto(photoAssetId: String, exifLocation: CLLocation?) async {
        let coord = QuickCaptureService.resolveCoordinate(liveFix: pendingLiveFix, exifLocation: exifLocation)
        guard let coord else {
            await MainActor.run {
                self.pendingPhotoAssetId = photoAssetId
                self.state = .manualPickNeeded
            }
            return
        }
        await MainActor.run { self.state = .resolvingPlace }
        let result = await QuickCaptureService.logCapture(
            coordinate: coord,
            photoAssetId: photoAssetId,
            in: context
        )
        await MainActor.run { self.state = .done(self.toast(from: result)) }
    }
```

Update `cancelCapture` to clear it:

```swift
    func cancelCapture() {
        pendingLiveFix = nil
        pendingPhotoAssetId = nil
        showCamera = false
        state = .idle
    }
```

- [ ] **Step 4: Simplify the shutter disabled logic**

The shutter `.disabled(...)` expression in step 2 is fragile. Replace it with a cleaner computed:

```swift
    private var isBusy: Bool {
        switch quickCapture.state {
        case .idle, .done: return false
        default: return true
        }
    }
```

And use `.disabled(isBusy)` on the shutter button.

- [ ] **Step 5: Wire QuickCaptureViewModel into the app**

In `PlaceNotes/PlaceNotesApp.swift`, inside `body`, after the existing `.environmentObject(makeTrackingViewModel())`, add:

```swift
                    .environmentObject(makeQuickCaptureViewModel())
```

Add the factory method to the `PlaceNotesApp` struct:

```swift
    @MainActor
    private func makeQuickCaptureViewModel() -> QuickCaptureViewModel {
        QuickCaptureViewModel(
            oneShot: LocationOneShot(),
            context: modelContainer.mainContext
        )
    }
```

- [ ] **Step 6: Regenerate project and build**

```bash
xcodegen generate
xcodebuild -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -quiet build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Run all tests**

```bash
xcodebuild test -scheme PlaceNotes -destination 'platform=iOS Simulator,name=iPhone 15' -quiet
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add PlaceNotes/Views/QuickCaptureToast.swift PlaceNotes/Views/TrackingControlView.swift PlaceNotes/ViewModels/QuickCaptureViewModel.swift PlaceNotes/PlaceNotesApp.swift project.pbxproj
git commit -m "feat: rewrite TrackingControlView with shutter-as-hero"
```

---

## Task 10: Device smoke test

**No files** — this is a manual verification step. Run on a real device (camera + Photos require it; simulator works for the permission flows but not camera capture).

- [ ] **Step 1: Happy path**

Enable tracking. Walk to a new place (or use a spot where no Place exists in the db). Tap shutter → grant camera + photos permission → take a photo → tap "Use Photo". Expect: toast `"Logged at <place name> · Undo"`. Open Logbook tab — new visit appears with 1-min duration. Tap it — the captured photo appears in the journal section.

- [ ] **Step 2: Merge path**

Stay at a place long enough for a dwell visit to start (or from the simulator, trigger one). While the dwell is active, tap shutter and capture a photo. Expect: toast `"Added to <place> · Split"`. Logbook shows only the original dwell visit; its journal contains the new photo. Tap "Split" within 4s → a second visit appears in the logbook at the same place.

- [ ] **Step 3: EXIF fallback**

Turn off Wi-Fi and wait for GPS to go stale (or enable Airplane Mode briefly). Tap shutter, take a photo. Expect: toast still appears because iOS embeds EXIF GPS from last known location. If EXIF is also nil (rare), the manual picker sheet opens.

- [ ] **Step 4: Manual picker path**

Revoke location permission temporarily (Settings → PlaceNotes → Location → Never). Tap shutter, capture photo. Expect: `ManualPlacePickerView` opens after save. Pick a known place → toast appears.

- [ ] **Step 5: Permission-denied**

Revoke camera. Tap shutter. Expect: nothing happens (no crash, no ghost state).

- [ ] **Step 6: Rapid tap**

Tap shutter twice quickly. Expect: only one camera sheet, no duplicate visits.

- [ ] **Step 7: Cancel camera**

Tap shutter, tap "Cancel" on camera. Expect: state returns to idle, no visit, no photo in library.

- [ ] **Step 8: Tracking-off capture**

Disable tracking from the chip. Tap shutter. Expect: capture works identically — one-shot location fires regardless of tracking state.

If any step fails, file the issue and fix before merging.

---

## Self-Review Summary

Spec coverage:
- D1 (no-signal hybrid) — Task 3 Step 3 (`resolveCoordinate` priority), Task 4 (`continueAfterPhoto` falls to manual pick), Task 6 (EXIF read).
- D2 (shutter hero layout) — Task 9.
- D3 (PHAsset + JournalEntry) — Task 4 (`savePhotoToLibrary`), Task 3 (`logCapture` creates entry).
- D4 (nearest-first 50m) — Task 1 (`nearestExisting`).
- D5 (merge + 30m window + split) — Task 3 (`mergeDecision` + `logCapture`), Task 4 (`splitFromMerge`).
- D6 (1-min visit) — Task 3 (`quickVisitDuration = 60`).
- D7 (one-shot) — Task 2 + Task 9 Step 5 (`LocationOneShot()` injected, independent of dwell manager).

Error handling: camera denied (Task 9 Step 1 fall-through); photos denied (Task 4 `ensureAddOnlyPhotosPermission`); save fails (Task 4 `error` state → alert); cancel camera (Task 4 `cancelCapture`); cancel manual picker (Task 7 `onCancelled`); duplicate taps (Task 9 Step 4 `isBusy`); location timeout → EXIF → manual (Task 4 `continueAfterPhoto`).

Not covered and **intentionally deferred:**
- Map-pin drop in `ManualPlacePickerView` (Task 7 note) — existing places cover 95% of cases.
- iPad-specific layout — inherits current behavior.
- "Photo saved, no place logged" toast when user cancels manual picker — currently silently returns to idle; acceptable since photo is still in the library and user knows what they did. Revisit if it causes confusion in smoke test.
