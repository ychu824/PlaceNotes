import Foundation
import SwiftData

/// A lightweight alternative place candidate stored as JSON on a Visit.
struct PlaceCandidate: Codable, Identifiable {
    var id: UUID = UUID()
    let name: String
    let latitude: Double
    let longitude: Double
    let category: String?
    let city: String?
    let state: String?
    let distanceMeters: Double
}

@Model
final class Visit {
    var id: UUID
    var arrivalDate: Date
    var departureDate: Date?
    var place: Place?

    /// JSON-encoded array of PlaceCandidate — the runner-up places from POI search.
    var alternativePlacesData: Data?

    /// How confidently this visit was resolved to a place.
    var confidenceRaw: String?

    /// Median horizontal accuracy of samples collected during the stay (meters).
    var medianAccuracyMeters: Double?

    var confidence: PlaceConfidence {
        get { PlaceConfidence(rawValue: confidenceRaw ?? "") ?? .medium }
        set { confidenceRaw = newValue.rawValue }
    }

    var alternativePlaces: [PlaceCandidate] {
        get {
            guard let data = alternativePlacesData else { return [] }
            return (try? JSONDecoder().decode([PlaceCandidate].self, from: data)) ?? []
        }
        set {
            alternativePlacesData = try? JSONEncoder().encode(newValue)
        }
    }

    var durationMinutes: Int {
        let end = departureDate ?? Date()
        return max(0, Int(end.timeIntervalSince(arrivalDate) / 60))
    }

    var timeOfDay: TimeOfDay {
        let hour = Calendar.current.component(.hour, from: arrivalDate)
        switch hour {
        case 5..<12: return .morning
        case 12..<17: return .afternoon
        case 17..<21: return .evening
        default: return .night
        }
    }

    var isActive: Bool {
        departureDate == nil
    }

    init(arrivalDate: Date, departureDate: Date? = nil, place: Place? = nil) {
        self.id = UUID()
        self.arrivalDate = arrivalDate
        self.departureDate = departureDate
        self.place = place
    }
}

enum TimeOfDay: String, CaseIterable, Codable {
    case morning = "Morning"
    case afternoon = "Afternoon"
    case evening = "Evening"
    case night = "Night"
}

/// Confidence level for how reliably a visit was resolved to a place.
/// - high: Good accuracy, long dwell, one clear POI nearby.
/// - medium: Decent address, multiple nearby businesses.
/// - low: Noisy location or no reliable POI — shows address fallback.
enum PlaceConfidence: String, Codable, CaseIterable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"
}
