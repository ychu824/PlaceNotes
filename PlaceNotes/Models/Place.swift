import Foundation
import SwiftData
import CoreLocation

@Model
final class Place {
    var id: UUID
    var name: String
    var nickname: String?
    var latitude: Double
    var longitude: Double
    var category: String?
    var customEmoji: String?

    /// Returns nickname if set, otherwise the auto-detected name.
    var displayName: String {
        if let nickname, !nickname.isEmpty {
            return nickname
        }
        return name
    }

    @Relationship(deleteRule: .cascade, inverse: \Visit.place)
    var visits: [Visit]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var totalTrackedMinutes: Int {
        visits.reduce(0) { $0 + $1.durationMinutes }
    }

    func qualifiedStays(minMinutes: Int) -> [Visit] {
        visits.filter { $0.durationMinutes >= minMinutes }
    }

    func qualifiedStayCount(minMinutes: Int) -> Int {
        qualifiedStays(minMinutes: minMinutes).count
    }

    func totalQualifiedMinutes(minMinutes: Int) -> Int {
        qualifiedStays(minMinutes: minMinutes).reduce(0) { $0 + $1.durationMinutes }
    }

    /// Returns the emoji for this place, preferring the user's custom emoji over the category default.
    var emoji: String {
        if let customEmoji, !customEmoji.isEmpty {
            return customEmoji
        }
        return PlaceCategorizer.emoji(for: category)
    }

    init(name: String, latitude: Double, longitude: Double, category: String? = nil, nickname: String? = nil) {
        self.id = UUID()
        self.name = name
        self.nickname = nickname
        self.latitude = latitude
        self.longitude = longitude
        self.category = category
        self.visits = []
    }
}
