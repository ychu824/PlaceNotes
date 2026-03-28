import Foundation
import CoreLocation
import SwiftData

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let clManager = CLLocationManager()
    private var modelContext: ModelContext?

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var currentVisit: Visit?
    @Published var userLocation: CLLocationCoordinate2D?

    var onVisitRecorded: ((Visit) -> Void)?

    // MARK: - Dwell detection
    // Tracks when the user stays near the same spot to create a visit,
    // since CLVisit can be delayed by hours or skip short stays entirely.

    private var dwellLocation: CLLocation?
    private var dwellStartDate: Date?
    private var lastRecordedDwellLocation: CLLocation?

    /// Distance (meters) the user must move before we consider them "left".
    private let dwellRadiusMeters: Double = 80

    /// Seconds the user must remain stationary to trigger a dwell visit.
    private let dwellThresholdSeconds: TimeInterval = 300 // 5 minutes

    override init() {
        super.init()
        clManager.delegate = self
        clManager.allowsBackgroundLocationUpdates = true
        clManager.pausesLocationUpdatesAutomatically = false
        clManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        clManager.distanceFilter = 50
        authorizationStatus = clManager.authorizationStatus
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func requestAuthorization() {
        clManager.requestAlwaysAuthorization()
    }

    func startMonitoring() {
        clManager.startMonitoringVisits()
        clManager.startMonitoringSignificantLocationChanges()
        clManager.startUpdatingLocation()
        print("[LocationManager] Started monitoring: visits + significant changes + location updates")
    }

    func stopMonitoring() {
        clManager.stopMonitoringVisits()
        clManager.stopMonitoringSignificantLocationChanges()
        clManager.stopUpdatingLocation()
        finalizeDwell()
        print("[LocationManager] Stopped all monitoring")
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedAlways ||
           manager.authorizationStatus == .authorizedWhenInUse {
            print("[LocationManager] Authorization granted: \(manager.authorizationStatus.rawValue)")
        }
    }

    /// Called by CLVisit monitoring — the gold standard, but can be delayed.
    func locationManager(_ manager: CLLocationManager, didVisit clVisit: CLVisit) {
        guard let modelContext else { return }

        let arrival = clVisit.arrivalDate
        let departure = clVisit.departureDate == .distantFuture ? nil : clVisit.departureDate

        print("[LocationManager] CLVisit received: \(clVisit.coordinate.latitude), \(clVisit.coordinate.longitude)")

        Task { @MainActor in
            let place = await findOrCreatePlace(
                latitude: clVisit.coordinate.latitude,
                longitude: clVisit.coordinate.longitude,
                in: modelContext
            )

            // Avoid duplicating a dwell-detected visit at the same place/time
            if isDuplicate(place: place, arrival: arrival) {
                print("[LocationManager] Skipping duplicate CLVisit for \(place.name)")
                return
            }

            let visit = Visit(arrivalDate: arrival, departureDate: departure, place: place)
            modelContext.insert(visit)
            try? modelContext.save()

            currentVisit = visit
            onVisitRecorded?(visit)
            print("[LocationManager] Recorded CLVisit at \(place.name)")
        }
    }

    /// Called by significant location changes AND periodic location updates.
    /// Used for dwell detection — if the user stays in the same area for
    /// `dwellThresholdSeconds`, we record a visit immediately instead of
    /// waiting for CLVisit (which can take hours).
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, let modelContext else { return }

        userLocation = location.coordinate

        // Start or update dwell tracking
        if let dwellLoc = dwellLocation {
            let distance = location.distance(from: dwellLoc)

            if distance < dwellRadiusMeters {
                // Still near the same spot — check if dwell threshold met
                if let start = dwellStartDate,
                   Date().timeIntervalSince(start) >= dwellThresholdSeconds {
                    // Record a dwell visit
                    recordDwellVisit(at: dwellLoc, arrival: start, context: modelContext)
                }
            } else {
                // Moved away — finalize previous dwell and start new one
                finalizeDwell()
                dwellLocation = location
                dwellStartDate = Date()
            }
        } else {
            // First location update — start tracking
            dwellLocation = location
            dwellStartDate = Date()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationManager] Error: \(error.localizedDescription)")
    }

    // MARK: - Dwell Visit Recording

    private func recordDwellVisit(at location: CLLocation, arrival: Date, context: ModelContext) {
        // Don't re-record the same dwell
        if let lastDwell = lastRecordedDwellLocation,
           location.distance(from: lastDwell) < dwellRadiusMeters {
            return
        }

        lastRecordedDwellLocation = location

        Task { @MainActor in
            let place = await findOrCreatePlace(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                in: context
            )

            if isDuplicate(place: place, arrival: arrival) {
                print("[LocationManager] Skipping duplicate dwell visit for \(place.name)")
                return
            }

            let visit = Visit(arrivalDate: arrival, departureDate: nil, place: place)
            context.insert(visit)
            try? context.save()

            currentVisit = visit
            onVisitRecorded?(visit)
            print("[LocationManager] Recorded dwell visit at \(place.name) (stayed \(Int(Date().timeIntervalSince(arrival)/60)) min)")
        }
    }

    /// Finalizes the current dwell by setting departure on the active visit.
    private func finalizeDwell() {
        guard let dwellLoc = dwellLocation,
              let modelContext else {
            dwellLocation = nil
            dwellStartDate = nil
            return
        }

        // Update departure time on the last visit at this location
        Task { @MainActor in
            let descriptor = FetchDescriptor<Visit>(
                predicate: #Predicate { $0.departureDate == nil },
                sortBy: [SortDescriptor(\.arrivalDate, order: .reverse)]
            )
            if let activeVisit = try? modelContext.fetch(descriptor).first,
               let place = activeVisit.place {
                let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
                if dwellLoc.distance(from: placeLocation) < dwellRadiusMeters {
                    activeVisit.departureDate = Date()
                    try? modelContext.save()
                    print("[LocationManager] Finalized departure for \(place.name)")
                }
            }
        }

        dwellLocation = nil
        dwellStartDate = nil
        lastRecordedDwellLocation = nil
    }

    // MARK: - Duplicate Detection

    @MainActor
    private func isDuplicate(place: Place, arrival: Date) -> Bool {
        // Consider it a duplicate if there's a visit to the same place
        // within 10 minutes of the same arrival time
        let threshold: TimeInterval = 600
        return place.visits.contains { visit in
            abs(visit.arrivalDate.timeIntervalSince(arrival)) < threshold
        }
    }

    // MARK: - Place Resolution

    @MainActor
    private func findOrCreatePlace(latitude: Double, longitude: Double, in context: ModelContext) async -> Place {
        let threshold = 0.0005 // ~50 meters

        let descriptor = FetchDescriptor<Place>()
        let allPlaces = (try? context.fetch(descriptor)) ?? []

        if let existing = allPlaces.first(where: {
            abs($0.latitude - latitude) < threshold && abs($0.longitude - longitude) < threshold
        }) {
            return existing
        }

        let name = await reverseGeocode(latitude: latitude, longitude: longitude)
        let categoryResult = await PlaceCategorizer.categorize(latitude: latitude, longitude: longitude)
        let place = Place(name: name, latitude: latitude, longitude: longitude, category: categoryResult?.label)
        context.insert(place)
        return place
    }

    private func reverseGeocode(latitude: Double, longitude: Double) async -> String {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                return placemark.name
                    ?? placemark.thoroughfare
                    ?? placemark.subLocality
                    ?? placemark.locality
                    ?? "Unknown Place"
            }
        } catch {
            print("Geocoding failed: \(error.localizedDescription)")
        }
        return "Unknown Place"
    }
}
