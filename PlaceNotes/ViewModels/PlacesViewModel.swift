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

        weeklyPlaces = ReportGenerator.frequentPlaces(
            from: places,
            since: sevenDaysAgo,
            minStayMinutes: settings.minStayMinutes
        )

        monthlyPlaces = ReportGenerator.frequentPlaces(
            from: places,
            since: thirtyDaysAgo,
            minStayMinutes: settings.minStayMinutes
        )
    }
}
