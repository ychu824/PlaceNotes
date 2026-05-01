# Day Trajectory on Map — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render a single day's GPS trajectory on a map (gradient by time of day) overlaid with that day's Place pins, reachable from each visit row in the Logbook.

**Architecture:** A new `DayTrajectoryView(day: Date)` SwiftUI screen queries `RawLocationSample` for the day, hands the samples to a pure `TrajectoryBuilder` (segment-split → point-convert → Douglas-Peucker simplify), and renders the result as N short `MapPolyline` segments — each colored by its midpoint's normalized time-of-day. Reuses the existing `PlaceAnnotationView` and `PlaceDetailSheet`.

**Tech Stack:** Swift 5.9, SwiftUI, SwiftData, MapKit (`Map`, `MapPolyline`), CoreLocation, XCTest, XcodeGen.

**Spec:** [`docs/superpowers/specs/2026-04-24-day-trajectory-on-map-design.md`](../specs/2026-04-24-day-trajectory-on-map-design.md)

**GitHub issue:** [#48](https://github.com/ychu824/PlaceNotes/issues/48)

---

## File Structure

**Create:**
- `PlaceNotes/Services/TrajectoryBuilder.swift` — pure `enum` with static methods: `splitIntoSegments`, `convertToPoints`, `simplify`, `computeStats`, `build`
- `PlaceNotes/Services/TrajectoryTypes.swift` — value types: `TrajectoryPoint`, `TrajectorySegment`, `TrajectoryStats`, `TrajectoryColorMode`
- `PlaceNotes/Views/TrajectoryHeaderCard.swift` — floating header card (date, distance, counts, AM→PM hint)
- `PlaceNotes/Views/TrajectoryPolyline.swift` — `MapContent`-conforming type that emits one `MapPolyline` per simplified pair, colored by midpoint normalized time-of-day
- `PlaceNotes/Views/DayTrajectoryView.swift` — the screen itself: query, transform, compose
- `PlaceNotesTests/TrajectoryBuilderTests.swift` — unit tests for the pure helpers

**Modify:**
- `PlaceNotes/Views/LogbookView.swift` — add a leading `swipeActions` "Map" button on `LogbookVisitRow`; push `DayTrajectoryView(day:)`

**Unchanged (reused):**
- `PlaceNotes/Models/RawLocationSample.swift`
- `PlaceNotes/Models/Visit.swift`, `Place.swift`
- `PlaceAnnotationView` and `PlaceDetailSheet` (both currently in `Views/FrequentPlacesMapView.swift`)

---

## Build & Test Commands

The project uses XcodeGen. Whenever you create a new `.swift` file under `PlaceNotes/` or `PlaceNotesTests/`, regenerate the Xcode project before building:

```bash
xcodegen generate
```

Run the test suite (adjust `name=iPhone 15 Pro` to whatever simulator is available locally — try `xcrun simctl list devices available` if unsure):

```bash
xcodebuild test \
  -scheme PlaceNotes \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro' \
  -only-testing:PlaceNotesTests/TrajectoryBuilderTests \
  | xcpretty
```

Whole-suite build for the final task:

```bash
xcodebuild build \
  -scheme PlaceNotes \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro' \
  | xcpretty
```

---

## Task 1: Add value types

**Files:**
- Create: `PlaceNotes/Services/TrajectoryTypes.swift`

These are plain value types with no behavior — they don't need tests. Creating them first gives every later task its vocabulary.

- [ ] **Step 1: Write the file**

```swift
import Foundation
import CoreLocation

struct TrajectoryPoint {
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    /// Position within the day's local 0:00–24:00 window, clamped to 0...1.
    let normalizedTimeOfDay: Double
    let speedMetersPerSecond: Double
}

struct TrajectorySegment {
    let points: [TrajectoryPoint]
}

struct TrajectoryStats {
    let totalDistanceMeters: Double
    let sampleCount: Int
    let segmentCount: Int
    let placeCount: Int
}

enum TrajectoryColorMode {
    case time
    case speed
    case plain
}
```

- [ ] **Step 2: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: prints "Created project at …/PlaceNotes.xcodeproj"

- [ ] **Step 3: Commit**

```bash
git add PlaceNotes/Services/TrajectoryTypes.swift project.yml
git commit -m "feat(trajectory): add value types for trajectory rendering"
```

---

## Task 2: `TrajectoryBuilder.splitIntoSegments` (TDD)

**Files:**
- Create: `PlaceNotes/Services/TrajectoryBuilder.swift`
- Create: `PlaceNotesTests/TrajectoryBuilderTests.swift`

Goal: split a chronologically sorted `[RawLocationSample]` into runs where consecutive samples are within `maxGapSeconds` of each other. A gap **strictly greater than** `maxGapSeconds` starts a new segment. A gap exactly equal to the threshold stays in the same segment.

- [ ] **Step 1: Create the empty module file (so the test file compiles)**

```swift
// PlaceNotes/Services/TrajectoryBuilder.swift
import Foundation
import CoreLocation

enum TrajectoryBuilder {
    static func splitIntoSegments(
        _ samples: [RawLocationSample],
        maxGapSeconds: TimeInterval
    ) -> [[RawLocationSample]] {
        fatalError("not implemented")
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `PlaceNotesTests/TrajectoryBuilderTests.swift`:

```swift
import XCTest
import CoreLocation
@testable import PlaceNotes

final class TrajectoryBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func sample(
        offsetSeconds: TimeInterval,
        from base: Date = Date(timeIntervalSince1970: 1_700_000_000),
        lat: Double = 37.78,
        lon: Double = -122.41,
        speed: Double = 0.5,
        accuracy: Double = 10
    ) -> RawLocationSample {
        RawLocationSample(
            latitude: lat,
            longitude: lon,
            timestamp: base.addingTimeInterval(offsetSeconds),
            horizontalAccuracy: accuracy,
            speed: speed,
            filterStatus: "accepted"
        )
    }

    // MARK: - splitIntoSegments

    func testSplitEmptyReturnsEmpty() {
        let segments = TrajectoryBuilder.splitIntoSegments([], maxGapSeconds: 600)
        XCTAssertTrue(segments.isEmpty)
    }

    func testSplitSingleSampleReturnsOneSegment() {
        let s = [sample(offsetSeconds: 0)]
        let segments = TrajectoryBuilder.splitIntoSegments(s, maxGapSeconds: 600)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].count, 1)
    }

    func testSplitNoGapStaysInOneSegment() {
        let s = [
            sample(offsetSeconds: 0),
            sample(offsetSeconds: 60),
            sample(offsetSeconds: 120),
            sample(offsetSeconds: 180)
        ]
        let segments = TrajectoryBuilder.splitIntoSegments(s, maxGapSeconds: 600)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].count, 4)
    }

    func testSplitOnGapAboveThreshold() {
        let s = [
            sample(offsetSeconds: 0),
            sample(offsetSeconds: 60),
            sample(offsetSeconds: 1000),  // 940s gap > 600s
            sample(offsetSeconds: 1060)
        ]
        let segments = TrajectoryBuilder.splitIntoSegments(s, maxGapSeconds: 600)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].count, 2)
        XCTAssertEqual(segments[1].count, 2)
    }

    func testSplitGapAtExactlyThresholdStaysInSameSegment() {
        let s = [
            sample(offsetSeconds: 0),
            sample(offsetSeconds: 600)  // gap == threshold
        ]
        let segments = TrajectoryBuilder.splitIntoSegments(s, maxGapSeconds: 600)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].count, 2)
    }

    func testSplitMultipleGapsProduceMultipleSegments() {
        let s = [
            sample(offsetSeconds: 0),
            sample(offsetSeconds: 700),   // gap 700 > 600
            sample(offsetSeconds: 1400),  // gap 700 > 600
            sample(offsetSeconds: 1460)
        ]
        let segments = TrajectoryBuilder.splitIntoSegments(s, maxGapSeconds: 600)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].count, 1)
        XCTAssertEqual(segments[1].count, 1)
        XCTAssertEqual(segments[2].count, 2)
    }
}
```

- [ ] **Step 3: Regenerate and run tests — verify they fail**

```bash
xcodegen generate
xcodebuild test \
  -scheme PlaceNotes \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro' \
  -only-testing:PlaceNotesTests/TrajectoryBuilderTests \
  | xcpretty
```
Expected: tests crash or fail with "not implemented" / fatalError.

- [ ] **Step 4: Implement `splitIntoSegments`**

Replace the file body with:

```swift
import Foundation
import CoreLocation

enum TrajectoryBuilder {
    /// Split a chronologically sorted run of samples wherever the temporal gap
    /// between consecutive samples is **strictly greater than** `maxGapSeconds`.
    /// Without this we would draw a "teleport" line across the gap.
    static func splitIntoSegments(
        _ samples: [RawLocationSample],
        maxGapSeconds: TimeInterval
    ) -> [[RawLocationSample]] {
        guard !samples.isEmpty else { return [] }

        var result: [[RawLocationSample]] = []
        var current: [RawLocationSample] = [samples[0]]

        for i in 1..<samples.count {
            let prev = samples[i - 1]
            let next = samples[i]
            if next.timestamp.timeIntervalSince(prev.timestamp) > maxGapSeconds {
                result.append(current)
                current = [next]
            } else {
                current.append(next)
            }
        }
        result.append(current)
        return result
    }
}
```

- [ ] **Step 5: Re-run tests — verify they pass**

Run the same `xcodebuild test` command from Step 3.
Expected: all 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add PlaceNotes/Services/TrajectoryBuilder.swift PlaceNotesTests/TrajectoryBuilderTests.swift project.yml
git commit -m "feat(trajectory): split sorted samples into segments at temporal gaps"
```

---

## Task 3: `TrajectoryBuilder.simplify` — Douglas–Peucker (TDD)

**Files:**
- Modify: `PlaceNotes/Services/TrajectoryBuilder.swift`
- Modify: `PlaceNotesTests/TrajectoryBuilderTests.swift`

Operates on `[TrajectoryPoint]`. The classic Douglas–Peucker algorithm: find the point with the largest perpendicular distance from the line between the first and last points; if that distance exceeds `epsilonMeters`, recurse on both halves; otherwise drop all interior points. Uses great-circle approximation: convert lat/lon to local meters via a flat-earth approximation around the segment's midpoint (good enough for the few-km scales we render).

- [ ] **Step 1: Add the failing tests**

Append to `PlaceNotesTests/TrajectoryBuilderTests.swift` (inside the existing class, after the previous tests):

```swift
    // MARK: - simplify (Douglas–Peucker)

    private func point(lat: Double, lon: Double) -> TrajectoryPoint {
        TrajectoryPoint(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            normalizedTimeOfDay: 0.5,
            speedMetersPerSecond: 1.0
        )
    }

    func testSimplifyEmptyReturnsEmpty() {
        let result = TrajectoryBuilder.simplify([], epsilonMeters: 5)
        XCTAssertTrue(result.isEmpty)
    }

    func testSimplifyTwoPointsReturnedUnchanged() {
        let pts = [point(lat: 37.78, lon: -122.41), point(lat: 37.79, lon: -122.42)]
        let result = TrajectoryBuilder.simplify(pts, epsilonMeters: 5)
        XCTAssertEqual(result.count, 2)
    }

    func testSimplifyColinearMiddleIsRemoved() {
        // Three points on roughly the same straight line — middle should drop.
        let pts = [
            point(lat: 37.7800, lon: -122.4100),
            point(lat: 37.7850, lon: -122.4100),
            point(lat: 37.7900, lon: -122.4100)
        ]
        let result = TrajectoryBuilder.simplify(pts, epsilonMeters: 5)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.coordinate.latitude, 37.7800, accuracy: 1e-6)
        XCTAssertEqual(result.last?.coordinate.latitude, 37.7900, accuracy: 1e-6)
    }

    func testSimplifySharpCornerIsKept() {
        // Three points forming a clear corner, far apart enough that the corner
        // exceeds the epsilon — middle should stay.
        let pts = [
            point(lat: 37.7800, lon: -122.4100),
            point(lat: 37.7800, lon: -122.4000),  // ~880m east
            point(lat: 37.7900, lon: -122.4000)   // ~1100m north
        ]
        let result = TrajectoryBuilder.simplify(pts, epsilonMeters: 50)
        XCTAssertEqual(result.count, 3)
    }

    func testSimplifyDenseColinearCollapses() {
        // 10 evenly spaced points on a straight line — should collapse to 2.
        let pts = (0..<10).map { i in
            point(lat: 37.78 + Double(i) * 0.0005, lon: -122.41)
        }
        let result = TrajectoryBuilder.simplify(pts, epsilonMeters: 5)
        XCTAssertEqual(result.count, 2)
    }
```

- [ ] **Step 2: Run tests — verify they fail to compile**

```bash
xcodebuild test \
  -scheme PlaceNotes \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro' \
  -only-testing:PlaceNotesTests/TrajectoryBuilderTests \
  | xcpretty
```
Expected: compile error — `TrajectoryBuilder.simplify` does not exist.

- [ ] **Step 3: Implement `simplify`**

Append to `PlaceNotes/Services/TrajectoryBuilder.swift` (inside the `enum TrajectoryBuilder { … }` body):

```swift
    /// Douglas–Peucker line simplification. Drops points whose perpendicular
    /// distance from the local approximation line is < `epsilonMeters`.
    /// Uses an equirectangular projection around the input's midpoint — good
    /// enough at the few-km scale a single day's path occupies.
    static func simplify(
        _ points: [TrajectoryPoint],
        epsilonMeters: Double
    ) -> [TrajectoryPoint] {
        guard points.count > 2 else { return points }

        let midLat = (points.first!.coordinate.latitude + points.last!.coordinate.latitude) / 2
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cos(midLat * .pi / 180)

        func project(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            (x: c.longitude * metersPerDegLon, y: c.latitude * metersPerDegLat)
        }

        func perpendicularDistance(
            _ p: CLLocationCoordinate2D,
            from a: CLLocationCoordinate2D,
            to b: CLLocationCoordinate2D
        ) -> Double {
            let pp = project(p), pa = project(a), pb = project(b)
            let dx = pb.x - pa.x
            let dy = pb.y - pa.y
            let lengthSq = dx * dx + dy * dy
            if lengthSq == 0 {
                let ex = pp.x - pa.x, ey = pp.y - pa.y
                return (ex * ex + ey * ey).squareRoot()
            }
            // |cross product| / |segment length|
            let cross = abs((pp.x - pa.x) * dy - (pp.y - pa.y) * dx)
            return cross / lengthSq.squareRoot()
        }

        // Recursive DP using indices into `points`.
        func recurse(start: Int, end: Int, into keep: inout [Bool]) {
            guard end > start + 1 else { return }
            var maxDist = 0.0
            var maxIdx = start
            let a = points[start].coordinate
            let b = points[end].coordinate
            for i in (start + 1)..<end {
                let d = perpendicularDistance(points[i].coordinate, from: a, to: b)
                if d > maxDist {
                    maxDist = d
                    maxIdx = i
                }
            }
            if maxDist > epsilonMeters {
                keep[maxIdx] = true
                recurse(start: start, end: maxIdx, into: &keep)
                recurse(start: maxIdx, end: end, into: &keep)
            }
        }

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        recurse(start: 0, end: points.count - 1, into: &keep)

        return zip(points, keep).compactMap { $0.1 ? $0.0 : nil }
    }
```

- [ ] **Step 4: Re-run tests — verify they pass**

Run the same `xcodebuild test` command from Step 2.
Expected: all simplify tests pass alongside the earlier split tests.

- [ ] **Step 5: Commit**

```bash
git add PlaceNotes/Services/TrajectoryBuilder.swift PlaceNotesTests/TrajectoryBuilderTests.swift
git commit -m "feat(trajectory): add Douglas-Peucker simplify for trajectory points"
```

---

## Task 4: `TrajectoryBuilder.computeStats` (TDD)

**Files:**
- Modify: `PlaceNotes/Services/TrajectoryBuilder.swift`
- Modify: `PlaceNotesTests/TrajectoryBuilderTests.swift`

Sums distances within each segment using `CLLocation.distance(from:)` for accurate great-circle math, plus aggregates counts.

- [ ] **Step 1: Add the failing tests**

Append inside the test class:

```swift
    // MARK: - computeStats

    func testComputeStatsEmpty() {
        let stats = TrajectoryBuilder.computeStats(segments: [], placeCount: 0)
        XCTAssertEqual(stats.totalDistanceMeters, 0)
        XCTAssertEqual(stats.sampleCount, 0)
        XCTAssertEqual(stats.segmentCount, 0)
        XCTAssertEqual(stats.placeCount, 0)
    }

    func testComputeStatsSingleSegmentTwoPoints() {
        // Two points ~111m apart in latitude (1/1000 of a degree).
        let seg = TrajectorySegment(points: [
            point(lat: 37.78000, lon: -122.41),
            point(lat: 37.78100, lon: -122.41)
        ])
        let stats = TrajectoryBuilder.computeStats(segments: [seg], placeCount: 2)
        XCTAssertEqual(stats.totalDistanceMeters, 111.32, accuracy: 1.0)
        XCTAssertEqual(stats.sampleCount, 2)
        XCTAssertEqual(stats.segmentCount, 1)
        XCTAssertEqual(stats.placeCount, 2)
    }

    func testComputeStatsMultipleSegmentsSumDistances() {
        let seg1 = TrajectorySegment(points: [
            point(lat: 37.78000, lon: -122.41),
            point(lat: 37.78100, lon: -122.41)  // ~111m
        ])
        let seg2 = TrajectorySegment(points: [
            point(lat: 37.79000, lon: -122.41),
            point(lat: 37.79200, lon: -122.41)  // ~222m
        ])
        let stats = TrajectoryBuilder.computeStats(segments: [seg1, seg2], placeCount: 3)
        XCTAssertEqual(stats.totalDistanceMeters, 333.96, accuracy: 2.0)
        XCTAssertEqual(stats.sampleCount, 4)
        XCTAssertEqual(stats.segmentCount, 2)
        XCTAssertEqual(stats.placeCount, 3)
    }

    func testComputeStatsSinglePointSegmentContributesZeroDistance() {
        let seg = TrajectorySegment(points: [point(lat: 37.78, lon: -122.41)])
        let stats = TrajectoryBuilder.computeStats(segments: [seg], placeCount: 0)
        XCTAssertEqual(stats.totalDistanceMeters, 0)
        XCTAssertEqual(stats.sampleCount, 1)
        XCTAssertEqual(stats.segmentCount, 1)
    }
```

- [ ] **Step 2: Run tests — verify compile failure**

Run the `xcodebuild test` command. Expected: compile error — `TrajectoryBuilder.computeStats` does not exist.

- [ ] **Step 3: Implement `computeStats`**

Append inside `enum TrajectoryBuilder { … }`:

```swift
    static func computeStats(
        segments: [TrajectorySegment],
        placeCount: Int
    ) -> TrajectoryStats {
        var totalDistance: Double = 0
        var totalSamples = 0

        for segment in segments {
            totalSamples += segment.points.count
            guard segment.points.count > 1 else { continue }
            for i in 1..<segment.points.count {
                let a = segment.points[i - 1].coordinate
                let b = segment.points[i].coordinate
                let aLoc = CLLocation(latitude: a.latitude, longitude: a.longitude)
                let bLoc = CLLocation(latitude: b.latitude, longitude: b.longitude)
                totalDistance += aLoc.distance(from: bLoc)
            }
        }

        return TrajectoryStats(
            totalDistanceMeters: totalDistance,
            sampleCount: totalSamples,
            segmentCount: segments.count,
            placeCount: placeCount
        )
    }
```

- [ ] **Step 4: Re-run tests — verify they pass**

Run the `xcodebuild test` command.
Expected: all stats tests pass.

- [ ] **Step 5: Commit**

```bash
git add PlaceNotes/Services/TrajectoryBuilder.swift PlaceNotesTests/TrajectoryBuilderTests.swift
git commit -m "feat(trajectory): compute aggregate stats from segments"
```

---

## Task 5: `TrajectoryBuilder.build` — top-level composition (TDD)

**Files:**
- Modify: `PlaceNotes/Services/TrajectoryBuilder.swift`
- Modify: `PlaceNotesTests/TrajectoryBuilderTests.swift`

`build(samples:day:epsilonMeters:maxGapSeconds:)` glues the pieces:

1. Split samples into segments by temporal gap.
2. For each segment, convert `RawLocationSample`s to `TrajectoryPoint`s, computing `normalizedTimeOfDay` from the **local-day** start.
3. Simplify each segment's points.
4. Drop segments that end up with < 2 points (not drawable as a polyline; per spec).

Defaults baked into the function: `epsilonMeters: 5`, `maxGapSeconds: 600` — callers can override.

- [ ] **Step 1: Add the failing tests**

Append inside the test class:

```swift
    // MARK: - build

    private func startOfDay(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = 0; comps.minute = 0; comps.second = 0
        return Calendar.current.date(from: comps)!
    }

    func testBuildEmptyReturnsEmpty() {
        let day = startOfDay(year: 2026, month: 4, day: 18)
        let result = TrajectoryBuilder.build(samples: [], day: day)
        XCTAssertTrue(result.isEmpty)
    }

    func testBuildAssignsNormalizedTimeOfDay() {
        let day = startOfDay(year: 2026, month: 4, day: 18)
        // 06:00 → 0.25, 12:00 → 0.5, 18:00 → 0.75
        let samples = [
            sample(offsetSeconds: 6 * 3600, from: day, lat: 37.78, lon: -122.41),
            sample(offsetSeconds: 12 * 3600, from: day, lat: 37.79, lon: -122.42),
            sample(offsetSeconds: 18 * 3600, from: day, lat: 37.80, lon: -122.43)
        ]
        let result = TrajectoryBuilder.build(samples: samples, day: day)
        // The 12h gap > 600s default → 3 segments of 1 point each → all dropped
        // (single-point segments are suppressed). Use a larger gap window to keep them:
        let allKept = TrajectoryBuilder.build(
            samples: samples,
            day: day,
            epsilonMeters: 0,
            maxGapSeconds: 24 * 3600
        )
        XCTAssertEqual(allKept.count, 1)
        XCTAssertEqual(allKept[0].points.count, 3)
        XCTAssertEqual(allKept[0].points[0].normalizedTimeOfDay, 0.25, accuracy: 0.001)
        XCTAssertEqual(allKept[0].points[1].normalizedTimeOfDay, 0.5, accuracy: 0.001)
        XCTAssertEqual(allKept[0].points[2].normalizedTimeOfDay, 0.75, accuracy: 0.001)

        // Default (600s gap) splits at every gap → all single-point segments → dropped.
        XCTAssertTrue(result.isEmpty)
    }

    func testBuildDropsSegmentsWithFewerThanTwoPoints() {
        let day = startOfDay(year: 2026, month: 4, day: 18)
        // Two close samples + one isolated sample → segment 1 keeps 2 pts, segment 2 drops.
        let samples = [
            sample(offsetSeconds: 6 * 3600, from: day),
            sample(offsetSeconds: 6 * 3600 + 60, from: day),
            sample(offsetSeconds: 18 * 3600, from: day)  // 12h gap
        ]
        let result = TrajectoryBuilder.build(samples: samples, day: day)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].points.count, 2)
    }

    func testBuildClampsNormalizedTimeOfDayToZeroOne() {
        // A sample whose timestamp is just before midnight of `day` (e.g., feature
        // pulls in samples that nominally landed in another day due to TZ rounding)
        // should not produce a negative normalizedTimeOfDay.
        let day = startOfDay(year: 2026, month: 4, day: 18)
        let earlier = sample(offsetSeconds: -10, from: day, lat: 37.78)
        let later = sample(offsetSeconds: 10, from: day, lat: 37.78)
        let result = TrajectoryBuilder.build(
            samples: [earlier, later],
            day: day,
            epsilonMeters: 0,
            maxGapSeconds: 600
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertGreaterThanOrEqual(result[0].points[0].normalizedTimeOfDay, 0)
        XCTAssertLessThanOrEqual(result[0].points[1].normalizedTimeOfDay, 1)
    }
```

- [ ] **Step 2: Run tests — verify compile failure**

Run the `xcodebuild test` command. Expected: compile error — `TrajectoryBuilder.build` does not exist.

- [ ] **Step 3: Implement `build` and the small `convertToPoints` helper**

Append inside `enum TrajectoryBuilder { … }`:

```swift
    static func build(
        samples: [RawLocationSample],
        day: Date,
        epsilonMeters: Double = 5,
        maxGapSeconds: TimeInterval = 600
    ) -> [TrajectorySegment] {
        let dayStart = Calendar.current.startOfDay(for: day)
        let raw = splitIntoSegments(samples, maxGapSeconds: maxGapSeconds)

        return raw.compactMap { rawSegment in
            let points = convertToPoints(rawSegment, dayStart: dayStart)
            let simplified = simplify(points, epsilonMeters: epsilonMeters)
            guard simplified.count >= 2 else { return nil }
            return TrajectorySegment(points: simplified)
        }
    }

    static func convertToPoints(
        _ samples: [RawLocationSample],
        dayStart: Date
    ) -> [TrajectoryPoint] {
        let dayLength: TimeInterval = 86_400
        return samples.map { s in
            let raw = s.timestamp.timeIntervalSince(dayStart) / dayLength
            let normalized = min(1.0, max(0.0, raw))
            return TrajectoryPoint(
                coordinate: CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude),
                timestamp: s.timestamp,
                normalizedTimeOfDay: normalized,
                speedMetersPerSecond: max(0, s.speed)
            )
        }
    }
```

- [ ] **Step 4: Re-run tests — verify they pass**

Run the `xcodebuild test` command. Expected: all `TrajectoryBuilderTests` (split, simplify, computeStats, build) pass.

- [ ] **Step 5: Commit**

```bash
git add PlaceNotes/Services/TrajectoryBuilder.swift PlaceNotesTests/TrajectoryBuilderTests.swift
git commit -m "feat(trajectory): top-level build composes split/convert/simplify"
```

---

## Task 6: `TrajectoryHeaderCard` view

**Files:**
- Create: `PlaceNotes/Views/TrajectoryHeaderCard.swift`

A small material-backed card. SwiftUI view with no internal logic — no unit tests in this codebase for views. Verified manually in Task 10.

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

struct TrajectoryHeaderCard: View {
    let day: Date
    let stats: TrajectoryStats?
    let isPathAvailable: Bool

    private var dayString: String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f.string(from: day)
    }

    private var distanceString: String {
        guard let meters = stats?.totalDistanceMeters else { return "—" }
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = meters >= 1000 ? 1 : 0
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        return formatter.string(from: measurement)
    }

    private var summaryString: String {
        guard let stats else { return "" }
        return "\(stats.placeCount) places · \(stats.sampleCount) samples"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dayString)
                .font(.subheadline.bold())
            HStack(spacing: 8) {
                if isPathAvailable {
                    Text(distanceString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(summaryString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Path data not available for this day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if isPathAvailable {
                Text("AM → PM")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }
}
```

- [ ] **Step 2: Regenerate and build (no tests for views)**

```bash
xcodegen generate
xcodebuild build \
  -scheme PlaceNotes \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro' \
  | xcpretty
```
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add PlaceNotes/Views/TrajectoryHeaderCard.swift project.yml
git commit -m "feat(trajectory): add header card view (date, distance, counts)"
```

---

## Task 7: `TrajectoryPolyline` map content

**Files:**
- Create: `PlaceNotes/Views/TrajectoryPolyline.swift`

Renders the gradient by emitting one `MapPolyline` per consecutive point pair, colored by the pair's midpoint normalized time-of-day. Implemented as a `MapContent`-conforming type so it composes inside a SwiftUI `Map { … }` content builder.

The `colorMode` parameter is wired in as the v2 extensibility seam — only `.time` is implemented for v1; `.speed` and `.plain` use a sensible fallback (plain accent color) so future code can flip the enum without crashing.

- [ ] **Step 1: Write the file**

```swift
import SwiftUI
import MapKit

struct TrajectoryPolyline: MapContent {
    let segments: [TrajectorySegment]
    let colorMode: TrajectoryColorMode

    var body: some MapContent {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
            ForEach(0..<max(0, segment.points.count - 1), id: \.self) { i in
                let a = segment.points[i]
                let b = segment.points[i + 1]
                MapPolyline(coordinates: [a.coordinate, b.coordinate])
                    .stroke(color(for: a, b), style: StrokeStyle(
                        lineWidth: 4,
                        lineCap: .round,
                        lineJoin: .round
                    ))
            }
        }
    }

    private func color(for a: TrajectoryPoint, _ b: TrajectoryPoint) -> Color {
        switch colorMode {
        case .time:
            let mid = (a.normalizedTimeOfDay + b.normalizedTimeOfDay) / 2
            return Self.timeColor(normalized: mid)
        case .speed, .plain:
            return .accentColor
        }
    }

    /// Maps 0...1 → AM yellow → PM orange → evening purple.
    static func timeColor(normalized t: Double) -> Color {
        let clamped = min(1.0, max(0.0, t))
        let amYellow = (r: 251.0/255, g: 191.0/255, b: 36.0/255)   // #fbbf24
        let pmOrange = (r: 251.0/255, g: 146.0/255, b: 60.0/255)   // #fb923c
        let evePurple = (r: 124.0/255, g: 58.0/255, b: 237.0/255)  // #7c3aed
        if clamped < 0.5 {
            let t2 = clamped / 0.5
            return Color(
                red: amYellow.r + (pmOrange.r - amYellow.r) * t2,
                green: amYellow.g + (pmOrange.g - amYellow.g) * t2,
                blue: amYellow.b + (pmOrange.b - amYellow.b) * t2
            )
        } else {
            let t2 = (clamped - 0.5) / 0.5
            return Color(
                red: pmOrange.r + (evePurple.r - pmOrange.r) * t2,
                green: pmOrange.g + (evePurple.g - pmOrange.g) * t2,
                blue: pmOrange.b + (evePurple.b - pmOrange.b) * t2
            )
        }
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate
xcodebuild build \
  -scheme PlaceNotes \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro' \
  | xcpretty
```
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add PlaceNotes/Views/TrajectoryPolyline.swift project.yml
git commit -m "feat(trajectory): render gradient polyline as per-pair MapPolylines"
```

---

## Task 8: `DayTrajectoryView` — the screen

**Files:**
- Create: `PlaceNotes/Views/DayTrajectoryView.swift`

Composes everything: queries samples and visits for the day, runs `TrajectoryBuilder.build`, renders header card + polyline + place pins inside a `Map`. Empty/sparse states handled per the spec.

Reuses `PlaceAnnotationView` and `PlaceDetailSheet` already defined in `FrequentPlacesMapView.swift`.

- [ ] **Step 1: Write the file**

```swift
import SwiftUI
import SwiftData
import MapKit

struct DayTrajectoryView: View {
    @Environment(\.modelContext) private var modelContext
    let day: Date

    @State private var segments: [TrajectorySegment] = []
    @State private var stats: TrajectoryStats?
    @State private var dayPlaces: [Place] = []
    @State private var selectedPlace: Place?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasLoaded = false

    private var isPathAvailable: Bool { !segments.isEmpty }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $cameraPosition, selection: $selectedPlace) {
                TrajectoryPolyline(segments: segments, colorMode: .time)

                ForEach(rankings(), id: \.id) { ranking in
                    Annotation(
                        ranking.place.displayName,
                        coordinate: ranking.place.coordinate
                    ) {
                        PlaceAnnotationView(ranking: ranking)
                    }
                    .tag(ranking.place)
                }
            }
            .mapStyle(.standard(showsTraffic: false))
            .mapControls {
                MapCompass()
                MapScaleView()
            }

            TrajectoryHeaderCard(day: day, stats: stats, isPathAvailable: isPathAvailable)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            if !isPathAvailable && dayPlaces.isEmpty {
                emptyOverlay
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedPlace) { place in
            PlaceDetailSheet(place: place)
                .presentationDetents([.medium])
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
    }

    private var navTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: day)
    }

    private var emptyOverlay: some View {
        VStack {
            Spacer()
            Text("No location data recorded for this day")
                .font(.callout)
                .padding(12)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 32)
        }
    }

    /// Build a synthetic ranking-per-place so we can reuse PlaceAnnotationView.
    /// `qualifiedStays` and `totalMinutes` here are scoped to this day only.
    private func rankings() -> [PlaceRanking] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        return dayPlaces.map { place in
            let visitsToday = place.visits.filter {
                $0.arrivalDate >= dayStart && $0.arrivalDate < dayEnd
            }
            let minutesToday = visitsToday.reduce(0) { $0 + $1.durationMinutes }
            return PlaceRanking(
                place: place,
                qualifiedStays: visitsToday.count,
                totalMinutes: minutesToday
            )
        }
    }

    private func load() async {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        let sampleDescriptor = FetchDescriptor<RawLocationSample>(
            predicate: #Predicate {
                $0.timestamp >= dayStart
                && $0.timestamp < dayEnd
                && $0.filterStatus == "accepted"
            },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let samples = (try? modelContext.fetch(sampleDescriptor)) ?? []

        let placeDescriptor = FetchDescriptor<Place>()
        let allPlaces = (try? modelContext.fetch(placeDescriptor)) ?? []
        let placesToday = allPlaces.filter { place in
            place.visits.contains { $0.arrivalDate >= dayStart && $0.arrivalDate < dayEnd }
        }

        let builtSegments = TrajectoryBuilder.build(samples: samples, day: day)
        let computedStats = TrajectoryBuilder.computeStats(
            segments: builtSegments,
            placeCount: placesToday.count
        )

        await MainActor.run {
            self.segments = builtSegments
            self.dayPlaces = placesToday
            self.stats = computedStats
            self.cameraPosition = initialCamera(segments: builtSegments, places: placesToday)
        }
    }

    private func initialCamera(
        segments: [TrajectorySegment],
        places: [Place]
    ) -> MapCameraPosition {
        var coords: [CLLocationCoordinate2D] = []
        coords.append(contentsOf: segments.flatMap { $0.points.map(\.coordinate) })
        coords.append(contentsOf: places.map(\.coordinate))
        guard !coords.isEmpty else { return .automatic }

        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.005, (lats.max()! - lats.min()!) * 1.4),
            longitudeDelta: max(0.005, (lons.max()! - lons.min()!) * 1.4)
        )
        return .region(MKCoordinateRegion(center: center, span: span))
    }
}
```

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate
xcodebuild build \
  -scheme PlaceNotes \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro' \
  | xcpretty
```
Expected: build succeeds. If `PlaceRanking` or `PlaceDetailSheet` are not visible, they live in `FrequentPlacesMapView.swift` — they're internal and should resolve from the same module.

- [ ] **Step 3: Commit**

```bash
git add PlaceNotes/Views/DayTrajectoryView.swift project.yml
git commit -m "feat(trajectory): DayTrajectoryView screen with map, header, pins"
```

---

## Task 9: Wire entry point into `LogbookView`

**Files:**
- Modify: `PlaceNotes/Views/LogbookView.swift`

Add a leading `swipeActions` "Map" button on every `LogbookVisitRow` (defined at the bottom of `LogbookView.swift`). Tapping it pushes `DayTrajectoryView(day:)` for the visit's local-day. The push uses a `NavigationLink` driven by an `@State` selection, so the swipe action just sets state.

- [ ] **Step 1: Add navigation state to `LogbookView`**

In `PlaceNotes/Views/LogbookView.swift`, inside the `LogbookView` struct's `@State` declarations (around line 9-12), add:

```swift
    @State private var trajectoryDay: Date?
```

- [ ] **Step 2: Add a `navigationDestination` to the root `NavigationStack`**

`navigationDestination(item:)` requires the item type to be `Hashable` — `Date` already is, so no wrapper is needed. Find the `.navigationTitle("Logbook")` modifier (around line 84). Replace:

```swift
            .navigationTitle("Logbook")
            .sheet(item: $visitForAlternatives) { visit in
```

with:

```swift
            .navigationTitle("Logbook")
            .navigationDestination(item: $trajectoryDay) { day in
                DayTrajectoryView(day: day)
            }
            .sheet(item: $visitForAlternatives) { visit in
```

- [ ] **Step 3: Pass an `onShowTrajectory` callback through `MonthSection` to `LogbookVisitRow`**

`MonthSection` (around line 285) needs to receive and forward a callback. Update its declaration:

```swift
private struct MonthSection: View {
    let year: Int
    let month: Int
    let visits: [Visit]
    var onPickAlternative: ((Visit) -> Void)?
    var onDelete: ((Visit) -> Void)?
    var onShowTrajectory: ((Date) -> Void)?
```

Inside `MonthSection.body`, find where `LogbookVisitRow` is constructed inside `.swipeActions(...)` (around line 321). Add a leading swipe action just above the existing trailing one:

```swift
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            onShowTrajectory?(visit.arrivalDate)
                        } label: {
                            Label("Map", systemImage: "map")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            onDelete?(visit)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
```

- [ ] **Step 4: Pass the callback from `LogbookView` into `MonthSection`**

In `LogbookView.body`, find the `MonthSection(...)` call (around line 56-67) and add the `onShowTrajectory` argument:

```swift
                                    MonthSection(
                                        year: yearGroup.year,
                                        month: monthGroup.month,
                                        visits: monthGroup.visits,
                                        onPickAlternative: { visit in
                                            visitForAlternatives = visit
                                        },
                                        onDelete: { visit in
                                            visitToDelete = visit
                                            showDeleteConfirmation = true
                                        },
                                        onShowTrajectory: { arrival in
                                            trajectoryDay = Calendar.current.startOfDay(for: arrival)
                                        }
                                    )
```

- [ ] **Step 5: Regenerate and build**

```bash
xcodegen generate
xcodebuild build \
  -scheme PlaceNotes \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro' \
  | xcpretty
```
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add PlaceNotes/Views/LogbookView.swift
git commit -m "feat(trajectory): add Map swipe action on Logbook visit rows"
```

---

## Task 10: Manual verification on simulator

**No code changes.** Spec compliance check on simulator with realistic data.

- [ ] **Step 1: Run all unit tests**

```bash
xcodebuild test \
  -scheme PlaceNotes \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15 Pro' \
  | xcpretty
```
Expected: all tests (existing + new `TrajectoryBuilderTests`) pass.

- [ ] **Step 2: Launch the app in simulator with seeded location data**

If the project has a debug seed action, use it. Otherwise: enable tracking in the simulator (Features → Location → Freeway Drive or Custom Location) for a few minutes to accumulate `RawLocationSample` rows and at least one `Visit`.

- [ ] **Step 3: Verify the golden path**

1. Open **Logbook** tab.
2. Expand a Month with at least one Visit.
3. Swipe right on a Visit row → blue **Map** button appears.
4. Tap **Map** → `DayTrajectoryView` pushes onto the nav stack.
5. Map shows: gradient polyline (yellow → purple), Place pins for that day's visits, header card with date / distance / counts.
6. Tap a Place pin → `PlaceDetailSheet` opens.
7. Back arrow → returns to Logbook.

- [ ] **Step 4: Verify edge cases**

- **Visit on a day with no `RawLocationSample` data** (e.g., a historical visit before tracking was on): header reads "Path data not available for this day", no overlay (because there are still pins), no path drawn.
- **A day with samples but no visits** (e.g., briefly tracked but never met dwell threshold): path renders alone, header reads "0 places · {n} samples".
- **Day with a phone-off gap > 10 minutes**: polyline visibly breaks at the gap (no straight line across).

- [ ] **Step 5: Final commit and push**

If verification surfaced no issues, no further commit needed. Otherwise commit fixes with descriptive messages, then:

```bash
git push -u origin feature/day-trajectory-on-map
```

(Only push when the user explicitly asks — confirm before running this step.)

---

## Summary

10 tasks: 5 of them strict TDD on `TrajectoryBuilder` (the algorithmic core), 3 view-creation tasks, 1 integration task on `LogbookView`, 1 manual verification. All commits on `feature/day-trajectory-on-map`. No changes to `LocationManager`, `RawLocationSample`, or any model layer.
