import Foundation
import SwiftData

@Model
final class Visit {
    var id: UUID
    var arrivalDate: Date
    var departureDate: Date?
    var place: Place?

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
