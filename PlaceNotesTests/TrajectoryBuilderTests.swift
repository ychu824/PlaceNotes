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
