import XCTest
import CoreLocation
@testable import PlaceNotes

final class StayDetectorTests: XCTestCase {

    // MARK: - Helper

    private func makeSample(
        lat: Double = 37.7830,
        lon: Double = -122.4090,
        accuracy: Double = 10,
        speed: Double = 0,
        timestamp: Date = Date()
    ) -> LocationSample {
        LocationSample(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            timestamp: timestamp,
            horizontalAccuracy: accuracy,
            speed: speed
        )
    }

    // MARK: - Weighted Center

    func testWeightedCenterSingleSample() {
        let sample = makeSample(lat: 37.78, lon: -122.41, accuracy: 10)
        let center = StayDetector.weightedCenter(of: [sample])
        XCTAssertEqual(center.latitude, 37.78, accuracy: 0.0001)
        XCTAssertEqual(center.longitude, -122.41, accuracy: 0.0001)
    }

    func testWeightedCenterEmptySamples() {
        let center = StayDetector.weightedCenter(of: [])
        XCTAssertEqual(center.latitude, 0)
        XCTAssertEqual(center.longitude, 0)
    }

    func testWeightedCenterFavorsAccurateSamples() {
        // Very accurate sample at lat 37.78
        let accurate = makeSample(lat: 37.78, lon: -122.41, accuracy: 5)
        // Noisy sample at lat 37.79 — should pull center only slightly
        let noisy = makeSample(lat: 37.79, lon: -122.41, accuracy: 50)

        let center = StayDetector.weightedCenter(of: [accurate, noisy])

        // Weight of accurate: 1/5 = 0.2, weight of noisy: 1/50 = 0.02
        // Expected lat ≈ (37.78*0.2 + 37.79*0.02) / 0.22 ≈ 37.7809
        XCTAssertEqual(center.latitude, 37.78, accuracy: 0.002)
        // Center should be much closer to the accurate sample
        XCTAssertLessThan(abs(center.latitude - 37.78), abs(center.latitude - 37.79))
    }

    func testWeightedCenterEqualAccuracyAveragesEvenly() {
        let s1 = makeSample(lat: 37.78, lon: -122.40, accuracy: 10)
        let s2 = makeSample(lat: 37.80, lon: -122.42, accuracy: 10)

        let center = StayDetector.weightedCenter(of: [s1, s2])

        XCTAssertEqual(center.latitude, 37.79, accuracy: 0.0001)
        XCTAssertEqual(center.longitude, -122.41, accuracy: 0.0001)
    }

    // MARK: - Build Cluster

    func testBuildClusterMedianAccuracyOddCount() {
        let samples = [
            makeSample(accuracy: 5),
            makeSample(accuracy: 15),
            makeSample(accuracy: 30),
        ]
        let cluster = StayDetector.buildCluster(from: samples, startDate: Date())
        XCTAssertEqual(cluster.medianAccuracy, 15)
    }

    func testBuildClusterMedianAccuracyEvenCount() {
        let samples = [
            makeSample(accuracy: 10),
            makeSample(accuracy: 20),
            makeSample(accuracy: 30),
            makeSample(accuracy: 40),
        ]
        let cluster = StayDetector.buildCluster(from: samples, startDate: Date())
        XCTAssertEqual(cluster.medianAccuracy, 25) // avg of 20 and 30
    }

    func testBuildClusterSpreadMeters() {
        // Two points roughly 110m apart (0.001 degrees latitude ≈ 111m)
        let samples = [
            makeSample(lat: 37.7800, lon: -122.41, accuracy: 10),
            makeSample(lat: 37.7810, lon: -122.41, accuracy: 10),
        ]
        let cluster = StayDetector.buildCluster(from: samples, startDate: Date())
        // Spread should be roughly half the distance (center is midpoint, spread is max from center)
        XCTAssertGreaterThan(cluster.spreadMeters, 40)
        XCTAssertLessThan(cluster.spreadMeters, 70)
    }

    func testBuildClusterSingleSampleZeroSpread() {
        let samples = [makeSample(accuracy: 10)]
        let cluster = StayDetector.buildCluster(from: samples, startDate: Date())
        XCTAssertEqual(cluster.spreadMeters, 0, accuracy: 0.1)
    }

    func testBuildClusterPreservesStartDate() {
        let date = Date(timeIntervalSince1970: 1000)
        let cluster = StayDetector.buildCluster(from: [makeSample()], startDate: date)
        XCTAssertEqual(cluster.startDate, date)
    }

    // MARK: - StayCluster.isAmbiguous

    func testClusterIsAmbiguousWhenSpreadExceeds100m() {
        // Points roughly 250m apart → spread ~125m
        let samples = [
            makeSample(lat: 37.7800, lon: -122.41, accuracy: 10),
            makeSample(lat: 37.7823, lon: -122.41, accuracy: 10),
        ]
        let cluster = StayDetector.buildCluster(from: samples, startDate: Date())
        XCTAssertTrue(cluster.isAmbiguous)
    }

    func testClusterNotAmbiguousWhenTight() {
        let samples = [
            makeSample(lat: 37.78000, lon: -122.41, accuracy: 10),
            makeSample(lat: 37.78005, lon: -122.41, accuracy: 10),
        ]
        let cluster = StayDetector.buildCluster(from: samples, startDate: Date())
        XCTAssertFalse(cluster.isAmbiguous)
    }

    // MARK: - Confidence Scoring

    func testHighConfidence() {
        // accuracy=10 (3pts) + dwell=1800s (3pts) + spread=20 (2pts) = 8 → high
        let confidence = StayDetector.computeConfidence(accuracy: 10, dwellSeconds: 1800, clusterSpread: 20)
        XCTAssertEqual(confidence, .high)
    }

    func testMediumConfidence() {
        // accuracy=25 (2pts) + dwell=600s (2pts) + spread=nil = 4 → medium
        let confidence = StayDetector.computeConfidence(accuracy: 25, dwellSeconds: 600, clusterSpread: nil)
        XCTAssertEqual(confidence, .medium)
    }

    func testLowConfidence() {
        // accuracy=80 (0pts) + dwell=120s (0pts) + spread=nil = 0 → low
        let confidence = StayDetector.computeConfidence(accuracy: 80, dwellSeconds: 120, clusterSpread: nil)
        XCTAssertEqual(confidence, .low)
    }

    func testConfidenceBoundaryHighAt6Points() {
        // accuracy=15 (3pts) + dwell=1800 (3pts) = 6 → high
        let confidence = StayDetector.computeConfidence(accuracy: 15, dwellSeconds: 1800, clusterSpread: nil)
        XCTAssertEqual(confidence, .high)
    }

    func testConfidenceBoundaryMediumAt3Points() {
        // accuracy=50 (1pt) + dwell=600 (2pts) = 3 → medium
        let confidence = StayDetector.computeConfidence(accuracy: 50, dwellSeconds: 600, clusterSpread: nil)
        XCTAssertEqual(confidence, .medium)
    }

    func testConfidenceLowAt2Points() {
        // accuracy=50 (1pt) + dwell=300 (1pt) = 2 → low
        let confidence = StayDetector.computeConfidence(accuracy: 50, dwellSeconds: 300, clusterSpread: nil)
        XCTAssertEqual(confidence, .low)
    }

    func testConfidenceAccuracyAbove50GetsZeroPoints() {
        // accuracy=51 (0pts) + dwell=1800 (3pts) + spread=20 (2pts) = 5 → medium
        let confidence = StayDetector.computeConfidence(accuracy: 51, dwellSeconds: 1800, clusterSpread: 20)
        XCTAssertEqual(confidence, .medium)
    }

    func testConfidenceSpreadScoring() {
        // accuracy=10 (3pts) + dwell=300 (1pt) + spread=25 (2pts) = 6 → high
        let tight = StayDetector.computeConfidence(accuracy: 10, dwellSeconds: 300, clusterSpread: 25)
        XCTAssertEqual(tight, .high)

        // accuracy=10 (3pts) + dwell=300 (1pt) + spread=80 (0pts) = 4 → medium
        let wide = StayDetector.computeConfidence(accuracy: 10, dwellSeconds: 300, clusterSpread: 80)
        XCTAssertEqual(wide, .medium)
    }

    func testConfidenceNilDwellAndSpread() {
        // accuracy=10 (3pts) only = 3 → medium
        let confidence = StayDetector.computeConfidence(accuracy: 10, dwellSeconds: nil, clusterSpread: nil)
        XCTAssertEqual(confidence, .medium)
    }

    // MARK: - Sample Filtering

    func testAcceptGoodSample() {
        XCTAssertTrue(StayDetector.shouldAcceptSample(
            horizontalAccuracy: 10,
            speed: 0,
            timestamp: Date()
        ))
    }

    func testRejectHighAccuracy() {
        XCTAssertFalse(StayDetector.shouldAcceptSample(
            horizontalAccuracy: 100,
            speed: 0,
            timestamp: Date()
        ))
    }

    func testRejectNegativeAccuracy() {
        // Negative accuracy means invalid
        XCTAssertFalse(StayDetector.shouldAcceptSample(
            horizontalAccuracy: -1,
            speed: 0,
            timestamp: Date()
        ))
    }

    func testRejectHighSpeed() {
        XCTAssertFalse(StayDetector.shouldAcceptSample(
            horizontalAccuracy: 10,
            speed: 5.0,
            timestamp: Date()
        ))
    }

    func testAcceptUnknownSpeed() {
        // speed < 0 means unknown — should be accepted
        XCTAssertTrue(StayDetector.shouldAcceptSample(
            horizontalAccuracy: 10,
            speed: -1,
            timestamp: Date()
        ))
    }

    func testRejectStaleSample() {
        XCTAssertFalse(StayDetector.shouldAcceptSample(
            horizontalAccuracy: 10,
            speed: 0,
            timestamp: Date().addingTimeInterval(-60)
        ))
    }

    func testAcceptBoundaryAccuracy() {
        XCTAssertTrue(StayDetector.shouldAcceptSample(
            horizontalAccuracy: 65,
            speed: 0,
            timestamp: Date()
        ))
    }

    func testAcceptBoundarySpeed() {
        XCTAssertTrue(StayDetector.shouldAcceptSample(
            horizontalAccuracy: 10,
            speed: 2.0,
            timestamp: Date()
        ))
    }
}
