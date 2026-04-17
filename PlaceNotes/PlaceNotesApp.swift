import SwiftUI
import SwiftData

@main
struct PlaceNotesApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var locationManager = LocationManager(settings: .shared)

    let modelContainer: ModelContainer

    init() {
        // Use separate stores so debug mock data never leaks into release
        #if DEBUG
        let storeName = "debug.store"
        #else
        let storeName = "release.store"
        #endif

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let storeURL = appSupport.appendingPathComponent(storeName)

        let makeContainer = {
            let config = ModelConfiguration(url: storeURL)
            return try ModelContainer(for: Place.self, Visit.self, CustomCategory.self, JournalEntry.self, RawLocationSample.self, configurations: config)
        }

        do {
            modelContainer = try makeContainer()
        } catch {
            // Schema migration failed — delete the old store and retry.
            // This is expected when new model fields are added during development.
            print("[PlaceNotesApp] Store incompatible, resetting: \(error.localizedDescription)")
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(at: storeURL.appendingPathExtension(suffix.isEmpty ? "" : String(suffix.dropFirst())))
                if suffix.isEmpty {
                    try? fm.removeItem(at: storeURL)
                } else {
                    try? fm.removeItem(atPath: storeURL.path + suffix)
                }
            }
            UserDefaults.standard.set(false, forKey: "mockDataSeeded_debug")

            do {
                modelContainer = try makeContainer()
            } catch {
                fatalError("Failed to create ModelContainer after reset: \(error)")
            }
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
                    Self.removeOldSharedStore()

                    #if DEBUG
                    MockLocationProvider.seedIfNeeded(context: modelContainer.mainContext)
                    #endif
                }
        }
        .modelContainer(modelContainer)
    }

    /// One-time cleanup: remove the old shared `default.store` that was used
    /// before debug/release stores were separated.
    private static func removeOldSharedStore() {
        let migrationKey = "migratedToSeparateStores"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let oldStore = appSupport.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            let path = oldStore.path + suffix
            try? fm.removeItem(atPath: path)
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
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
