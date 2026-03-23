import Foundation
import CoreLocation
import SwiftData

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let clManager = CLLocationManager()
    private var modelContext: ModelContext?

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var currentVisit: Visit?

    var onVisitRecorded: ((Visit) -> Void)?

    override init() {
        super.init()
        clManager.delegate = self
        clManager.allowsBackgroundLocationUpdates = true
        clManager.pausesLocationUpdatesAutomatically = false
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
    }

    func stopMonitoring() {
        clManager.stopMonitoringVisits()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didVisit clVisit: CLVisit) {
        guard let modelContext else { return }

        let arrival = clVisit.arrivalDate
        let departure = clVisit.departureDate == .distantFuture ? nil : clVisit.departureDate

        Task { @MainActor in
            let place = await findOrCreatePlace(
                latitude: clVisit.coordinate.latitude,
                longitude: clVisit.coordinate.longitude,
                in: modelContext
            )

            let visit = Visit(arrivalDate: arrival, departureDate: departure, place: place)
            modelContext.insert(visit)
            try? modelContext.save()

            currentVisit = visit
            onVisitRecorded?(visit)
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
        let place = Place(name: name, latitude: latitude, longitude: longitude)
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
