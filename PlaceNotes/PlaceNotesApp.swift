import SwiftUI
import SwiftData

@main
struct PlaceNotesApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var locationManager = LocationManager(settings: .shared)

    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: Place.self, Visit.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(locationManager)
                .environmentObject(makeTrackingViewModel())
                .onAppear {
                    NotificationManager.shared.requestAuthorization()
                    locationManager.configure(modelContext: modelContainer.mainContext)

                    #if DEBUG
                    MockLocationProvider.seedIfNeeded(context: modelContainer.mainContext)
                    #else
                    MockLocationProvider.purgeIfNeeded(context: modelContainer.mainContext)
                    #endif
                }
        }
        .modelContainer(modelContainer)
    }

    @MainActor
    private func makeTrackingViewModel() -> TrackingViewModel {
        let trackingManager = TrackingManager(locationManager: locationManager, settings: settings)

        locationManager.onVisitRecorded = { visit in
            if let place = visit.place {
                NotificationManager.shared.checkMilestone(for: place)
            }
        }

        return TrackingViewModel(trackingManager: trackingManager)
    }
}
