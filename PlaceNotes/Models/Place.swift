import Foundation
import SwiftData
import CoreLocation

@Model
final class Place {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var category: String?

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

    init(name: String, latitude: Double, longitude: Double, category: String? = nil) {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.category = category
        self.visits = []
    }
}
