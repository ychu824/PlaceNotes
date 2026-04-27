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

    /// Douglas–Peucker line simplification. Drops points whose perpendicular
    /// distance from the local approximation line is < `epsilonMeters`.
    /// Uses an equirectangular projection around the input's midpoint — good
    /// enough at the few-km scale a single day's path occupies.
    static func simplify(
        _ points: [TrajectoryPoint],
        epsilonMeters: Double
    ) -> [TrajectoryPoint] {
        guard points.count > 2 else { return points }

        let midLat = (points[0].coordinate.latitude + points[points.count - 1].coordinate.latitude) / 2
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
            let cross = abs((pp.x - pa.x) * dy - (pp.y - pa.y) * dx)
            return cross / lengthSq.squareRoot()
        }

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

    private static func convertToPoints(
        _ samples: [RawLocationSample],
        dayStart: Date
    ) -> [TrajectoryPoint] {
        // Use the calendar to compute day length so DST transitions (23h or 25h
        // local days) produce a normalizedTimeOfDay that doesn't drift past 1.
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let dayLength = nextDay.timeIntervalSince(dayStart)

        return samples.map { s in
            let raw = s.timestamp.timeIntervalSince(dayStart) / dayLength
            let normalized = min(1.0, max(0.0, raw))
            // CoreLocation reports speed = -1 when unknown. v1 doesn't render
            // speed, so coerce to 0; if the v2 .speed color mode lands, this
            // should be revisited (likely promote speedMetersPerSecond to optional).
            let speed = max(0, s.speed)
            return TrajectoryPoint(
                coordinate: CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude),
                timestamp: s.timestamp,
                normalizedTimeOfDay: normalized,
                speedMetersPerSecond: speed
            )
        }
    }
}
