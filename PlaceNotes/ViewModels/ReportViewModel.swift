import Foundation

@MainActor
final class ReportViewModel: ObservableObject {
    @Published var report: MonthlyReport?

    private let settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    func generateReport(places: [Place]) {
        report = ReportGenerator.generateMonthlyReport(
            places: places,
            minStayMinutes: settings.minStayMinutes
        )
    }
}
