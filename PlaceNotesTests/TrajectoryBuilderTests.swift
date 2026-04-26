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
        let pts = [
            point(lat: 37.7800, lon: -122.4100),
            point(lat: 37.7850, lon: -122.4100),
            point(lat: 37.7900, lon: -122.4100)
        ]
        let result = TrajectoryBuilder.simplify(pts, epsilonMeters: 5)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.coordinate.latitude ?? 0, 37.7800, accuracy: 1e-6)
        XCTAssertEqual(result.last?.coordinate.latitude ?? 0, 37.7900, accuracy: 1e-6)
    }

    func testSimplifySharpCornerIsKept() {
        let pts = [
            point(lat: 37.7800, lon: -122.4100),
            point(lat: 37.7800, lon: -122.4000),
            point(lat: 37.7900, lon: -122.4000)
        ]
        let result = TrajectoryBuilder.simplify(pts, epsilonMeters: 50)
        XCTAssertEqual(result.count, 3)
    }

    func testSimplifyDenseColinearCollapses() {
        let pts = (0..<10).map { i in
            point(lat: 37.78 + Double(i) * 0.0005, lon: -122.41)
        }
        let result = TrajectoryBuilder.simplify(pts, epsilonMeters: 5)
        XCTAssertEqual(result.count, 2)
    }
}
