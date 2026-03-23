import Foundation

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var minStayMinutes: Int {
        didSet { UserDefaults.standard.set(minStayMinutes, forKey: "minStayMinutes") }
    }

    @Published var milestoneVisitCounts: [Int] {
        didSet { UserDefaults.standard.set(milestoneVisitCounts, forKey: "milestoneVisitCounts") }
    }

    @Published var trackingState: TrackingState {
        didSet {
            if let data = try? JSONEncoder().encode(trackingState) {
                UserDefaults.standard.set(data, forKey: "trackingState")
            }
        }
    }

    private init() {
        let savedMin = UserDefaults.standard.integer(forKey: "minStayMinutes")
        self.minStayMinutes = savedMin > 0 ? savedMin : 10

        let savedMilestones = UserDefaults.standard.array(forKey: "milestoneVisitCounts") as? [Int]
        self.milestoneVisitCounts = savedMilestones ?? [5, 10, 25, 50, 100]

        if let data = UserDefaults.standard.data(forKey: "trackingState"),
           let state = try? JSONDecoder().decode(TrackingState.self, from: data) {
            self.trackingState = state
        } else {
            self.trackingState = .default
        }
    }
}
