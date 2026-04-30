#if DEBUG
import Foundation
import SwiftData

/// Generates synthetic Places, Visits, and RawLocationSamples so the trajectory
/// feature can be exercised on a fresh simulator without waiting hours for
/// real CoreLocation fixes. DEBUG builds only.
///
/// All generated samples are marked `filterStatus = "accepted"` so the
/// trajectory query (which filters to accepted samples) renders the full path.
/// In real-world use the LocationManager classifies samples with speed > 2 m/s
/// as "rejected-speed", so on-device data won't include the driving segments —
/// the seed therefore shows the *intended* feature behavior, which is more
/// useful for verification than real data would be.
enum DebugSeed {

    @MainActor
    static func seedSampleTrajectories(in context: ModelContext) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let home = Coord(lat: 37.7649, lon: -122.4194)
        let coffee = Coord(lat: 37.7706, lon: -122.4128)
        let work = Coord(lat: 37.7858, lon: -122.4065)
        let restaurant = Coord(lat: 37.7795, lon: -122.4143)

        let homePlace = Place(name: "Home", latitude: home.lat, longitude: home.lon, category: "Home", city: "San Francisco", state: "CA")
        let coffeePlace = Place(name: "Blue Bottle Coffee", latitude: coffee.lat, longitude: coffee.lon, category: "Café", city: "San Francisco", state: "CA")
        let workPlace = Place(name: "Office", latitude: work.lat, longitude: work.lon, category: "Work", city: "San Francisco", state: "CA")
        let restaurantPlace = Place(name: "Tartine", latitude: restaurant.lat, longitude: restaurant.lon, category: "Restaurant", city: "San Francisco", state: "CA")

        for place in [homePlace, coffeePlace, workPlace, restaurantPlace] {
            context.insert(place)
        }

        var samples: [RawLocationSample] = []

        // Day 0 (today) — golden path: Home → Coffee → Work → Restaurant → Home.
        seedGoldenPath(
            day: today,
            home: home, coffee: coffee, work: work, restaurant: restaurant,
            homePlace: homePlace, coffeePlace: coffeePlace,
            workPlace: workPlace, restaurantPlace: restaurantPlace,
            samples: &samples,
            context: context
        )

        // Day -1 — samples but no qualifying visits (just transit through SF).
        let dayMinus1 = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let routeStart = Coord(lat: 37.7649, lon: -122.4194)
        let routeMid1 = Coord(lat: 37.7700, lon: -122.4150)
        let routeMid2 = Coord(lat: 37.7750, lon: -122.4100)
        let routeEnd = Coord(lat: 37.7800, lon: -122.4050)
        samples += transitSamples(from: routeStart, to: routeMid1, start: timeOf(day: dayMinus1, hour: 10, minute: 0), end: timeOf(day: dayMinus1, hour: 10, minute: 30))
        samples += transitSamples(from: routeMid1, to: routeMid2, start: timeOf(day: dayMinus1, hour: 10, minute: 30), end: timeOf(day: dayMinus1, hour: 11, minute: 0))
        samples += transitSamples(from: routeMid2, to: routeEnd, start: timeOf(day: dayMinus1, hour: 11, minute: 0), end: timeOf(day: dayMinus1, hour: 11, minute: 30))

        // Day -2 — visits but no GPS samples (e.g., feature added after this history existed).
        let dayMinus2 = calendar.date(byAdding: .day, value: -2, to: today) ?? today
        let visitNoSamples1 = Visit(arrivalDate: timeOf(day: dayMinus2, hour: 9, minute: 0), departureDate: timeOf(day: dayMinus2, hour: 9, minute: 30), place: coffeePlace)
        let visitNoSamples2 = Visit(arrivalDate: timeOf(day: dayMinus2, hour: 10, minute: 0), departureDate: timeOf(day: dayMinus2, hour: 17, minute: 0), place: workPlace)
        for v in [visitNoSamples1, visitNoSamples2] {
            v.confidence = .high
            v.medianAccuracyMeters = 12
            context.insert(v)
        }

        // Day -3 — phone-off gap > 10 min (polyline should visibly break).
        let dayMinus3 = calendar.date(byAdding: .day, value: -3, to: today) ?? today
        let gapVisit1 = Visit(arrivalDate: timeOf(day: dayMinus3, hour: 8, minute: 0), departureDate: timeOf(day: dayMinus3, hour: 8, minute: 30), place: homePlace)
        let gapVisit2 = Visit(arrivalDate: timeOf(day: dayMinus3, hour: 11, minute: 0), departureDate: timeOf(day: dayMinus3, hour: 12, minute: 0), place: workPlace)
        for v in [gapVisit1, gapVisit2] {
            v.confidence = .high
            v.medianAccuracyMeters = 12
            context.insert(v)
        }
        samples += clusterSamples(at: home, start: timeOf(day: dayMinus3, hour: 8, minute: 0), end: timeOf(day: dayMinus3, hour: 8, minute: 30), interval: 60)
        // 8:30 → 10:50 = 140-minute gap — phone off.
        samples += transitSamples(from: home, to: work, start: timeOf(day: dayMinus3, hour: 10, minute: 50), end: timeOf(day: dayMinus3, hour: 11, minute: 0))
        samples += clusterSamples(at: work, start: timeOf(day: dayMinus3, hour: 11, minute: 0), end: timeOf(day: dayMinus3, hour: 12, minute: 0), interval: 60)

        for sample in samples {
            context.insert(sample)
        }

        try? context.save()
    }

    @MainActor
    static func clearAllData(in context: ModelContext) {
        deleteAll(of: RawLocationSample.self, in: context)
        deleteAll(of: JournalEntry.self, in: context)
        deleteAll(of: Visit.self, in: context)
        deleteAll(of: Place.self, in: context)
        try? context.save()
    }

    // MARK: - Day 0 (golden path)

    @MainActor
    private static func seedGoldenPath(
        day: Date,
        home: Coord, coffee: Coord, work: Coord, restaurant: Coord,
        homePlace: Place, coffeePlace: Place, workPlace: Place, restaurantPlace: Place,
        samples: inout [RawLocationSample],
        context: ModelContext
    ) {
        let visits = [
            Visit(arrivalDate: timeOf(day: day, hour: 8, minute: 0),  departureDate: timeOf(day: day, hour: 8, minute: 30), place: homePlace),
            Visit(arrivalDate: timeOf(day: day, hour: 8, minute: 40), departureDate: timeOf(day: day, hour: 9, minute: 5),  place: coffeePlace),
            Visit(arrivalDate: timeOf(day: day, hour: 9, minute: 20), departureDate: timeOf(day: day, hour: 17, minute: 30), place: workPlace),
            Visit(arrivalDate: timeOf(day: day, hour: 18, minute: 0), departureDate: timeOf(day: day, hour: 19, minute: 30), place: restaurantPlace),
            Visit(arrivalDate: timeOf(day: day, hour: 19, minute: 50), departureDate: timeOf(day: day, hour: 22, minute: 0), place: homePlace)
        ]
        for v in visits {
            v.confidence = .high
            v.medianAccuracyMeters = 12
            context.insert(v)
        }

        samples += clusterSamples(at: home,       start: timeOf(day: day, hour: 8,  minute: 0),  end: timeOf(day: day, hour: 8,  minute: 30), interval: 60)
        samples += transitSamples(from: home,     to: coffee,     start: timeOf(day: day, hour: 8,  minute: 30), end: timeOf(day: day, hour: 8,  minute: 40))
        samples += clusterSamples(at: coffee,     start: timeOf(day: day, hour: 8,  minute: 40), end: timeOf(day: day, hour: 9,  minute: 5),  interval: 60)
        samples += transitSamples(from: coffee,   to: work,       start: timeOf(day: day, hour: 9,  minute: 5),  end: timeOf(day: day, hour: 9,  minute: 20))
        // Sparse during the workday — OS slows updates when stationary.
        samples += clusterSamples(at: work,       start: timeOf(day: day, hour: 9,  minute: 20), end: timeOf(day: day, hour: 17, minute: 30), interval: 300)
        samples += transitSamples(from: work,     to: restaurant, start: timeOf(day: day, hour: 17, minute: 30), end: timeOf(day: day, hour: 18, minute: 0))
        samples += clusterSamples(at: restaurant, start: timeOf(day: day, hour: 18, minute: 0),  end: timeOf(day: day, hour: 19, minute: 30), interval: 60)
        samples += transitSamples(from: restaurant, to: home,     start: timeOf(day: day, hour: 19, minute: 30), end: timeOf(day: day, hour: 19, minute: 50))
        samples += clusterSamples(at: home,       start: timeOf(day: day, hour: 19, minute: 50), end: timeOf(day: day, hour: 22, minute: 0),  interval: 300)
    }

    // MARK: - Sample generators

    private struct Coord {
        let lat: Double
        let lon: Double
    }

    private static func clusterSamples(at point: Coord, start: Date, end: Date, interval: TimeInterval) -> [RawLocationSample] {
        var result: [RawLocationSample] = []
        var t = start
        while t <= end {
            let jitterLat = Double.random(in: -0.00005...0.00005)
            let jitterLon = Double.random(in: -0.00005...0.00005)
            result.append(RawLocationSample(
                latitude: point.lat + jitterLat,
                longitude: point.lon + jitterLon,
                timestamp: t,
                horizontalAccuracy: Double.random(in: 8...15),
                speed: 0,
                altitude: 50,
                verticalAccuracy: 5,
                course: nil,
                filterStatus: "accepted"
            ))
            t = t.addingTimeInterval(interval)
        }
        return result
    }

    private static func transitSamples(from a: Coord, to b: Coord, start: Date, end: Date) -> [RawLocationSample] {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return [] }
        let intervalSec: TimeInterval = 20
        let count = max(2, Int(duration / intervalSec))
        var result: [RawLocationSample] = []
        for i in 0...count {
            let progress = Double(i) / Double(count)
            let lat = a.lat + (b.lat - a.lat) * progress + Double.random(in: -0.00003...0.00003)
            let lon = a.lon + (b.lon - a.lon) * progress + Double.random(in: -0.00003...0.00003)
            let timestamp = start.addingTimeInterval(duration * progress)
            result.append(RawLocationSample(
                latitude: lat,
                longitude: lon,
                timestamp: timestamp,
                horizontalAccuracy: Double.random(in: 8...15),
                speed: 1.5,
                altitude: 50,
                verticalAccuracy: 5,
                course: nil,
                filterStatus: "accepted"
            ))
        }
        return result
    }

    // MARK: - Time helper

    private static func timeOf(day: Date, hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    // MARK: - Bulk delete helper

    @MainActor
    private static func deleteAll<T: PersistentModel>(of type: T.Type, in context: ModelContext) {
        let descriptor = FetchDescriptor<T>()
        let items = (try? context.fetch(descriptor)) ?? []
        for item in items {
            context.delete(item)
        }
    }
}
#endif
