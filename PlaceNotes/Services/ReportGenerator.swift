import Foundation
import SwiftData

struct PlaceRanking: Identifiable {
    let id = UUID()
    let place: Place
    let qualifiedStays: Int
    let totalMinutes: Int
}

struct MonthlyReport: Identifiable {
    let id = UUID()
    let month: String
    let topPlaces: [PlaceRanking]
    let totalTrackedMinutes: Int
    let preferredTimeOfDay: TimeOfDay
    let visitsByTimeOfDay: [TimeOfDay: Int]
    let totalVisits: Int
}

final class ReportGenerator {

    /// Returns places ranked by qualified stay count, then total minutes.
    static func frequentPlaces(
        from places: [Place],
        since startDate: Date,
        minStayMinutes: Int
    ) -> [PlaceRanking] {
        places.compactMap { place in
            let recentVisits = place.visits.filter { $0.arrivalDate >= startDate }
            let qualified = recentVisits.filter { $0.durationMinutes >= minStayMinutes }
            guard !qualified.isEmpty else { return nil }
            let totalMin = qualified.reduce(0) { $0 + $1.durationMinutes }
            return PlaceRanking(place: place, qualifiedStays: qualified.count, totalMinutes: totalMin)
        }
        .sorted { ($0.qualifiedStays, $0.totalMinutes) > ($1.qualifiedStays, $1.totalMinutes) }
    }

    /// Generates a monthly consolidated report.
    static func generateMonthlyReport(
        places: [Place],
        minStayMinutes: Int,
        referenceDate: Date = Date()
    ) -> MonthlyReport {
        let calendar = Calendar.current
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: referenceDate))!

        let allVisitsThisMonth = places.flatMap { $0.visits }
            .filter { $0.arrivalDate >= startOfMonth }

        let topPlaces = frequentPlaces(from: places, since: startOfMonth, minStayMinutes: minStayMinutes)

        let totalMinutes = allVisitsThisMonth.reduce(0) { $0 + $1.durationMinutes }

        var timeOfDayCounts: [TimeOfDay: Int] = [:]
        for visit in allVisitsThisMonth {
            timeOfDayCounts[visit.timeOfDay, default: 0] += 1
        }

        let preferredTime = timeOfDayCounts.max(by: { $0.value < $1.value })?.key ?? .morning

        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"

        return MonthlyReport(
            month: formatter.string(from: referenceDate),
            topPlaces: Array(topPlaces.prefix(10)),
            totalTrackedMinutes: totalMinutes,
            preferredTimeOfDay: preferredTime,
            visitsByTimeOfDay: timeOfDayCounts,
            totalVisits: allVisitsThisMonth.count
        )
    }
}
