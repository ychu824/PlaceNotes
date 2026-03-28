import Foundation
import SwiftData

#if DEBUG
/// Provides simulated location visits for debug builds.
/// Generates sample places and visits so you can test the UI without moving around.
final class MockLocationProvider {

    struct MockPlace {
        let name: String
        let latitude: Double
        let longitude: Double
        let category: String
    }

    static let samplePlaces: [MockPlace] = [
        MockPlace(name: "Blue Bottle Coffee", latitude: 37.7830, longitude: -122.4090, category: "Cafe"),
        MockPlace(name: "Whole Foods Market", latitude: 37.7850, longitude: -122.4070, category: "Grocery"),
        MockPlace(name: "Barry's Bootcamp", latitude: 37.7870, longitude: -122.4050, category: "Gym"),
        MockPlace(name: "Nobu Restaurant", latitude: 37.7860, longitude: -122.3900, category: "Restaurant"),
        MockPlace(name: "San Francisco Library", latitude: 37.7790, longitude: -122.4160, category: "Library"),
        MockPlace(name: "Chase Bank", latitude: 37.7900, longitude: -122.4000, category: "Bank"),
        MockPlace(name: "Golden Gate Park", latitude: 37.7694, longitude: -122.4862, category: "Park"),
        MockPlace(name: "UCSF Medical Center", latitude: 37.7631, longitude: -122.4580, category: "Hospital"),
    ]

    /// Seeds the database with sample places and visits spread over the past 30 days.
    @MainActor
    static func seedIfNeeded(context: ModelContext) {
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
                category: mockPlace.category
            )
            context.insert(place)

            // Generate random visits over the past 30 days
            let visitCount = Int.random(in: 3...15)
            for i in 0..<visitCount {
                let daysAgo = Int.random(in: 0...29)
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
                context.insert(visit)
            }
        }

        try? context.save()
        print("[MockLocationProvider] Seeded \(samplePlaces.count) places with sample visits")
    }
}
#endif
