import Foundation
import SwiftData

@MainActor
final class PlacesViewModel: ObservableObject {
    @Published var weeklyPlaces: [PlaceRanking] = []
    @Published var monthlyPlaces: [PlaceRanking] = []

    private let settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    func refresh(places: [Place]) {
        let now = Date()
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        let minStay = settings.minStayMinutes

        // Snapshot the data needed for ranking so we can compute off the main thread
        let snapshots = places.map { place -> (Place, [(Date, Int)]) in
            let visitData = place.visits.map { ($0.arrivalDate, $0.durationMinutes) }
            return (place, visitData)
        }

        Task.detached {
            let weekly = Self.computeRankings(from: snapshots, since: sevenDaysAgo, minStayMinutes: minStay)
            let monthly = Self.computeRankings(from: snapshots, since: thirtyDaysAgo, minStayMinutes: minStay)

            await MainActor.run {
                self.weeklyPlaces = weekly
                self.monthlyPlaces = monthly
            }
        }
    }

    private nonisolated static func computeRankings(
        from snapshots: [(Place, [(Date, Int)])],
        since startDate: Date,
        minStayMinutes: Int
    ) -> [PlaceRanking] {
        snapshots.compactMap { place, visits in
            let qualified = visits.filter { $0.0 >= startDate && $0.1 >= minStayMinutes }
            guard !qualified.isEmpty else { return nil }
            let totalMin = qualified.reduce(0) { $0 + $1.1 }
            return PlaceRanking(place: place, qualifiedStays: qualified.count, totalMinutes: totalMin)
        }
        .sorted { ($0.qualifiedStays, $0.totalMinutes) > ($1.qualifiedStays, $1.totalMinutes) }
    }
}
