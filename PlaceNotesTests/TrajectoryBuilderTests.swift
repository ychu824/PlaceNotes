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

    // MARK: - computeStats

    func testComputeStatsEmpty() {
        let stats = TrajectoryBuilder.computeStats(segments: [], rawSampleCount: 0, placeCount: 0)
        XCTAssertEqual(stats.totalDistanceMeters, 0)
        XCTAssertEqual(stats.rawSampleCount, 0)
        XCTAssertEqual(stats.segmentCount, 0)
        XCTAssertEqual(stats.placeCount, 0)
    }

    func testComputeStatsSingleSegmentTwoPoints() {
        let seg = TrajectorySegment(points: [
            point(lat: 37.78000, lon: -122.41),
            point(lat: 37.78100, lon: -122.41)
        ])
        let stats = TrajectoryBuilder.computeStats(segments: [seg], rawSampleCount: 2, placeCount: 2)
        XCTAssertEqual(stats.totalDistanceMeters, 111.32, accuracy: 1.0)
        XCTAssertEqual(stats.rawSampleCount, 2)
        XCTAssertEqual(stats.segmentCount, 1)
        XCTAssertEqual(stats.placeCount, 2)
    }

    func testComputeStatsMultipleSegmentsSumDistances() {
        let seg1 = TrajectorySegment(points: [
            point(lat: 37.78000, lon: -122.41),
            point(lat: 37.78100, lon: -122.41)
        ])
        let seg2 = TrajectorySegment(points: [
            point(lat: 37.79000, lon: -122.41),
            point(lat: 37.79200, lon: -122.41)
        ])
        let stats = TrajectoryBuilder.computeStats(segments: [seg1, seg2], rawSampleCount: 4, placeCount: 3)
        XCTAssertEqual(stats.totalDistanceMeters, 333.96, accuracy: 2.0)
        XCTAssertEqual(stats.rawSampleCount, 4)
        XCTAssertEqual(stats.segmentCount, 2)
        XCTAssertEqual(stats.placeCount, 3)
    }

    func testComputeStatsSinglePointSegmentContributesZeroDistance() {
        let seg = TrajectorySegment(points: [point(lat: 37.78, lon: -122.41)])
        let stats = TrajectoryBuilder.computeStats(segments: [seg], rawSampleCount: 1, placeCount: 0)
        XCTAssertEqual(stats.totalDistanceMeters, 0)
        XCTAssertEqual(stats.rawSampleCount, 1)
        XCTAssertEqual(stats.segmentCount, 1)
        XCTAssertEqual(stats.placeCount, 0)
    }

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
}
