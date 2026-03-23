import SwiftUI
import SwiftData

@main
struct PlaceNotesApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var locationManager = LocationManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(makeTrackingViewModel())
                .onAppear {
                    NotificationManager.shared.requestAuthorization()
                }
        }
        .modelContainer(for: [Place.self, Visit.self])
    }

    @MainActor
    private func makeTrackingViewModel() -> TrackingViewModel {
        let trackingManager = TrackingManager(locationManager: locationManager, settings: settings)

        // Wire up milestone notifications
        locationManager.onVisitRecorded = { visit in
            if let place = visit.place {
                NotificationManager.shared.checkMilestone(for: place)
            }
        }

        return TrackingViewModel(trackingManager: trackingManager)
    }
}
