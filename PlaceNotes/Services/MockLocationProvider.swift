import Foundation
import SwiftData

/// Provides simulated location visits for debug builds and
/// cleans up mock data when switching to release.
final class MockLocationProvider {

    private static let seededKey = "mockDataSeeded_debug"
    /// Bump this version to force a re-seed (e.g. after adding new mock fields).
    private static let seedVersion = 2
    private static let seedVersionKey = "mockDataSeedVersion"

    /// Whether mock data has been seeded into the current debug database.
    static var hasSeededData: Bool {
        UserDefaults.standard.bool(forKey: seededKey)
    }

    /// Whether the seeded data is up-to-date with the current seed version.
    static var isCurrentVersion: Bool {
        UserDefaults.standard.integer(forKey: seedVersionKey) >= seedVersion
    }

    struct MockPlace {
        let name: String
        let latitude: Double
        let longitude: Double
        let category: String
        let city: String
        let state: String
    }

    static let samplePlaces: [MockPlace] = [
        MockPlace(name: "Blue Bottle Coffee", latitude: 37.7830, longitude: -122.4090, category: "Cafe", city: "San Francisco", state: "CA"),
        MockPlace(name: "Whole Foods Market", latitude: 37.7850, longitude: -122.4070, category: "Grocery", city: "San Francisco", state: "CA"),
        MockPlace(name: "Barry's Bootcamp", latitude: 37.7870, longitude: -122.4050, category: "Gym", city: "San Francisco", state: "CA"),
        MockPlace(name: "Nobu Restaurant", latitude: 37.7860, longitude: -122.3900, category: "Restaurant", city: "San Francisco", state: "CA"),
        MockPlace(name: "San Francisco Library", latitude: 37.7790, longitude: -122.4160, category: "Library", city: "San Francisco", state: "CA"),
        MockPlace(name: "Chase Bank", latitude: 37.7900, longitude: -122.4000, category: "Bank", city: "San Francisco", state: "CA"),
        MockPlace(name: "Golden Gate Park", latitude: 37.7694, longitude: -122.4862, category: "Park", city: "San Francisco", state: "CA"),
        MockPlace(name: "UCSF Medical Center", latitude: 37.7631, longitude: -122.4580, category: "Hospital", city: "San Francisco", state: "CA"),
    ]

    /// Seeds the database with sample places and visits spread over the past 30 days.
    /// Only runs once per install and only in DEBUG builds.
    @MainActor
    static func seedIfNeeded(context: ModelContext) {
        // Re-seed if version changed (e.g. new mock fields added)
        if hasSeededData && !isCurrentVersion {
            purgeIfNeeded(context: context)
        }

        guard !hasSeededData else { return }

        let descriptor = FetchDescriptor<Place>()
        let existingCount = (try? context.fetchCount(descriptor)) ?? 0
        guard existingCount == 0 else { return }

        let calendar = Calendar.current
        let now = Date()

        for mockPlace in samplePlaces {
            let place = Place(
                name: mockPlace.name,
                latitude: mockPlace.latitude,
                longitude: mockPlace.longitude,
                category: mockPlace.category,
                city: mockPlace.city,
                state: mockPlace.state
            )
            context.insert(place)

            // Generate random visits over the past 90 days (spans multiple months)
            let visitCount = Int.random(in: 5...20)
            for _ in 0..<visitCount {
                let daysAgo = Int.random(in: 0...89)
                let hour = Int.random(in: 6...22)
                let minute = Int.random(in: 0...59)
                let durationMinutes = Int.random(in: 5...180)

                var components = calendar.dateComponents([.year, .month, .day], from: now)
                components.day! -= daysAgo
                components.hour = hour
                components.minute = minute

                guard let arrival = calendar.date(from: components) else { continue }
                let departure = arrival.addingTimeInterval(Double(durationMinutes) * 60)

                let visit = Visit(arrivalDate: arrival, departureDate: departure, place: place)

                // Give ~half the visits some alternative place candidates so
                // the "Wrong Place?" feature can be tested in debug builds.
                if Bool.random() {
                    let others = samplePlaces.filter { $0.name != mockPlace.name }.shuffled()
                    visit.alternativePlaces = Array(others.prefix(2)).map { alt in
                        PlaceCandidate(
                            name: alt.name,
                            latitude: alt.latitude,
                            longitude: alt.longitude,
                            category: alt.category,
                            city: alt.city,
                            state: alt.state,
                            distanceMeters: Double.random(in: 30...200)
                        )
                    }
                }

                context.insert(visit)
            }
        }

        try? context.save()
        UserDefaults.standard.set(true, forKey: seededKey)
        UserDefaults.standard.set(seedVersion, forKey: seedVersionKey)
        print("[MockLocationProvider] Seeded \(samplePlaces.count) places with sample visits (v\(seedVersion))")
    }

    /// Known mock place names used to detect legacy seeded data
    /// that was inserted before the `mockDataSeeded` flag existed.
    private static let mockPlaceNames: Set<String> = Set(samplePlaces.map(\.name))

    /// Removes all mock-seeded data from the database.
    /// Call this in release builds to clean up leftover debug data.
    /// Detects mock data both by the UserDefaults flag AND by matching
    /// against known mock place names (handles data seeded before the flag existed).
    @MainActor
    static func purgeIfNeeded(context: ModelContext) {
        let placeDescriptor = FetchDescriptor<Place>()
        guard let places = try? context.fetch(placeDescriptor) else { return }

        let hasMockPlaces = places.contains { mockPlaceNames.contains($0.name) }
        guard hasSeededData || hasMockPlaces else { return }

        // Only delete places that match known mock names and their visits
        for place in places where mockPlaceNames.contains(place.name) {
            for visit in place.visits {
                context.delete(visit)
            }
            context.delete(place)
        }

        try? context.save()
        UserDefaults.standard.set(false, forKey: seededKey)
        print("[MockLocationProvider] Purged mock data for release build")
    }
}
