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
