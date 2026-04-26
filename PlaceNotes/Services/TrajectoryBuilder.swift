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
