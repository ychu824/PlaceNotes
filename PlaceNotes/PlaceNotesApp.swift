import SwiftUI
import SwiftData

@main
struct PlaceNotesApp: App {
    let settings: AppSettings
    let locationManager: LocationManager
    let trackingManager: TrackingManager
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

        let container: ModelContainer
        do {
            container = try makeContainer()
        } catch {
            // Schema migration failed — delete the old store and retry.
            // This is expected when new model fields are added during development.
            print("[PlaceNotesApp] Store incompatible, resetting: \(error.localizedDescription)")
            Self.deleteStoreFiles(at: storeURL)
            UserDefaults.standard.set(false, forKey: "mockDataSeeded_debug")

            do {
                container = try makeContainer()
            } catch {
                fatalError("Failed to create ModelContainer after reset: \(error)")
            }
        }
        self.modelContainer = container

        let settings = AppSettings.shared
        self.settings = settings

        // Wire up LocationManager with the model context in init() rather than
        // onAppear so background-only relaunches via significant location changes
        // (where the SwiftUI scene never appears) still persist samples and
        // resume tracking.
        let locationManager = LocationManager(settings: settings)
        locationManager.configure(modelContext: container.mainContext)
        locationManager.onVisitRecorded = { visit in
            if let place = visit.place {
                NotificationManager.shared.checkMilestone(for: place)
            }
        }
        self.locationManager = locationManager

        // TrackingManager.init -> checkPauseExpiry auto-resumes monitoring when
        // the persisted state is .active, which is what makes background
        // relaunches actually start collecting again.
        self.trackingManager = TrackingManager(locationManager: locationManager, settings: settings)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(locationManager)
                .environmentObject(makeTrackingViewModel())
                .environmentObject(makeQuickCaptureViewModel())
                .onAppear {
                    NotificationManager.shared.requestAuthorization()
                    Self.removeOldSharedStore()

                    #if DEBUG
                    MockLocationProvider.seedIfNeeded(context: modelContainer.mainContext)
                    #endif
                }
        }
        .modelContainer(modelContainer)
    }

    private static func deleteStoreFiles(at storeURL: URL) {
        let fm = FileManager.default
        let urls = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
        for url in urls {
            try? fm.removeItem(at: url)
        }
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
    private func makeQuickCaptureViewModel() -> QuickCaptureViewModel {
        QuickCaptureViewModel(
            oneShot: LocationOneShot(),
            context: modelContainer.mainContext
        )
    }

    @MainActor
    private func makeTrackingViewModel() -> TrackingViewModel {
        TrackingViewModel(trackingManager: trackingManager)
    }
}
