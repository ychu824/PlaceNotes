import Foundation
import CoreLocation

/// Pure-function helpers for stay detection: clustering, weighted centers, and confidence scoring.
/// Extracted from LocationManager so they can be unit-tested without CLLocationManager.
enum StayDetector {

    /// Maximum accuracy (meters) to attempt venue labeling. Beyond this, fall back to address.
    static let maxAccuracyForVenueLabel: CLLocationAccuracy = 50

    // MARK: - Weighted Center

    /// Compute a weighted center from samples, giving more weight to more accurate ones.
    /// Weight = 1 / horizontalAccuracy (clamped to min 1.0).
    static func weightedCenter(of samples: [LocationSample]) -> CLLocationCoordinate2D {
        guard !samples.isEmpty else {
            return CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }

        var totalWeight: Double = 0
        var weightedLat: Double = 0
        var weightedLon: Double = 0

        for s in samples {
            let weight = 1.0 / max(s.horizontalAccuracy, 1.0)
            weightedLat += s.coordinate.latitude * weight
            weightedLon += s.coordinate.longitude * weight
            totalWeight += weight
        }

        return CLLocationCoordinate2D(
            latitude: weightedLat / totalWeight,
            longitude: weightedLon / totalWeight
        )
    }

    // MARK: - Cluster Building

    /// Build a StayCluster from collected samples.
    static func buildCluster(from samples: [LocationSample], startDate: Date) -> StayCluster {
        let center = weightedCenter(of: samples)
        let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)

        let spread = samples.map { s in
            CLLocation(latitude: s.coordinate.latitude, longitude: s.coordinate.longitude)
                .distance(from: centerLoc)
        }.max() ?? 0

        let sortedAccuracies = samples.map(\.horizontalAccuracy).sorted()
        let medianAccuracy: Double
        if sortedAccuracies.isEmpty {
            medianAccuracy = 100
        } else if sortedAccuracies.count % 2 == 0 {
            medianAccuracy = (sortedAccuracies[sortedAccuracies.count / 2 - 1] + sortedAccuracies[sortedAccuracies.count / 2]) / 2
        } else {
            medianAccuracy = sortedAccuracies[sortedAccuracies.count / 2]
        }

        return StayCluster(
            samples: samples,
            center: center,
            startDate: startDate,
            medianAccuracy: medianAccuracy,
            spreadMeters: spread
        )
    }

    // MARK: - Confidence

    /// Determine confidence based on accuracy, dwell time, and cluster spread.
    static func computeConfidence(accuracy: Double, dwellSeconds: TimeInterval?, clusterSpread: Double?) -> PlaceConfidence {
        var score = 0

        // Accuracy scoring
        if accuracy <= 15 { score += 3 }
        else if accuracy <= 30 { score += 2 }
        else if accuracy <= maxAccuracyForVenueLabel { score += 1 }

        // Dwell time scoring
        if let dwell = dwellSeconds {
            if dwell >= 1800 { score += 3 }       // 30+ min
            else if dwell >= 600 { score += 2 }    // 10+ min
            else if dwell >= 300 { score += 1 }    // 5+ min
        }

        // Cluster spread scoring (lower is better)
        if let spread = clusterSpread {
            if spread <= 30 { score += 2 }
            else if spread <= 60 { score += 1 }
        }

        if score >= 6 { return .high }
        if score >= 3 { return .medium }
        return .low
    }

    // MARK: - Sample Filtering

    /// Whether a location sample should be accepted based on accuracy, speed, and freshness.
    static func shouldAcceptSample(
        horizontalAccuracy: CLLocationAccuracy,
        speed: CLLocationSpeed,
        timestamp: Date,
        maxAccuracy: CLLocationAccuracy = 65,
        maxSpeed: CLLocationSpeed = 2.0,
        maxAge: TimeInterval = 30
    ) -> Bool {
        let isAccurate = horizontalAccuracy >= 0 && horizontalAccuracy <= maxAccuracy
        let isStationary = speed < 0 || speed <= maxSpeed
        let isRecent = abs(timestamp.timeIntervalSinceNow) < maxAge
        return isAccurate && isStationary && isRecent
    }
}
