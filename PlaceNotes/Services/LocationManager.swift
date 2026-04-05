import Foundation
import CoreLocation
import MapKit
import SwiftData
import os

private let logger = Logger(subsystem: "com.placenotes.app", category: "LocationManager")

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let clManager = CLLocationManager()
    private var modelContext: ModelContext?

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var currentVisit: Visit?
    @Published var userLocation: CLLocationCoordinate2D?

    var onVisitRecorded: ((Visit) -> Void)?

    // MARK: - Dwell detection

    private var dwellLocation: CLLocation?
    private var dwellStartDate: Date?
    private var lastRecordedDwellLocation: CLLocation?
    private var dwellTimer: Timer?
    private let settings: AppSettings

    /// Distance (meters) the user must move before we consider them "left".
    private let dwellRadiusMeters: Double = 80

    /// Seconds the user must remain stationary to trigger a dwell visit.
    /// Reads from AppSettings.minStayMinutes so the user's configured threshold
    /// controls both report qualification AND dwell detection.
    private var dwellThresholdSeconds: TimeInterval {
        TimeInterval(settings.minStayMinutes * 60)
    }

    init(settings: AppSettings = .shared) {
        self.settings = settings
        super.init()
        clManager.delegate = self
        clManager.allowsBackgroundLocationUpdates = true
        clManager.pausesLocationUpdatesAutomatically = false
        clManager.desiredAccuracy = kCLLocationAccuracyBest
        clManager.distanceFilter = 10 // meters — frequent enough for dwell detection without flooding the main thread
        authorizationStatus = clManager.authorizationStatus
        logger.info("LocationManager initialized, auth status: \(self.authorizationStatus.rawValue), minStay: \(settings.minStayMinutes)min")
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        logger.info("ModelContext configured")
    }

    func requestAuthorization() {
        logger.info("Requesting always authorization")
        clManager.requestAlwaysAuthorization()
    }

    func startMonitoring() {
        logger.notice(">>> Starting all monitoring <<<")
        clManager.startMonitoringVisits()
        clManager.startMonitoringSignificantLocationChanges()
        clManager.startUpdatingLocation()
        startDwellTimer()
        logger.notice("Monitoring started: visits + significant changes + location updates + dwell timer")
    }

    func stopMonitoring() {
        logger.notice(">>> Stopping all monitoring <<<")
        clManager.stopMonitoringVisits()
        clManager.stopMonitoringSignificantLocationChanges()
        clManager.stopUpdatingLocation()
        dwellTimer?.invalidate()
        dwellTimer = nil
        finalizeDwell()
        logger.notice("All monitoring stopped")
    }

    // MARK: - Dwell Timer
    // Since the simulator (and stationary real devices) may not fire
    // didUpdateLocations frequently enough, we use a periodic timer
    // to check dwell status independently.

    private func startDwellTimer() {
        dwellTimer?.invalidate()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkDwellStatus()
        }
        logger.debug("Dwell timer started (30s interval)")
    }

    private func checkDwellStatus() {
        guard let dwellLoc = dwellLocation,
              let start = dwellStartDate,
              let modelContext else {
            logger.debug("Dwell timer tick — no active dwell location")
            return
        }

        let elapsed = Date().timeIntervalSince(start)
        logger.info("Dwell timer tick — dwelling for \(Int(elapsed))s at (\(dwellLoc.coordinate.latitude), \(dwellLoc.coordinate.longitude))")

        let threshold = dwellThresholdSeconds
        if elapsed >= threshold {
            logger.notice("Dwell threshold reached (\(Int(elapsed))s >= \(Int(threshold))s from minStay=\(self.settings.minStayMinutes)min) — recording visit")
            recordDwellVisit(at: dwellLoc, arrival: start, context: modelContext)
        } else {
            let remaining = Int(threshold - elapsed)
            logger.info("Dwell threshold not yet met — \(remaining)s remaining (threshold=\(Int(threshold))s from minStay=\(self.settings.minStayMinutes)min)")
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let old = authorizationStatus
        authorizationStatus = manager.authorizationStatus
        logger.notice("Authorization changed: \(old.rawValue) -> \(manager.authorizationStatus.rawValue)")

        switch manager.authorizationStatus {
        case .notDetermined:
            logger.warning("Authorization: not determined")
        case .restricted:
            logger.error("Authorization: restricted")
        case .denied:
            logger.error("Authorization: denied — location tracking will not work")
        case .authorizedWhenInUse:
            logger.notice("Authorization: when in use (consider requesting Always for background tracking)")
        case .authorizedAlways:
            logger.notice("Authorization: always — full background tracking enabled")
        @unknown default:
            logger.warning("Authorization: unknown value \(manager.authorizationStatus.rawValue)")
        }
    }

    func locationManager(_ manager: CLLocationManager, didVisit clVisit: CLVisit) {
        logger.notice("CLVisit received: (\(clVisit.coordinate.latitude), \(clVisit.coordinate.longitude))")
        logger.info("  arrival: \(clVisit.arrivalDate)")
        logger.info("  departure: \(clVisit.departureDate == .distantFuture ? "still here" : "\(clVisit.departureDate)")")

        guard let modelContext else {
            logger.error("CLVisit ignored — modelContext is nil")
            return
        }

        let arrival = clVisit.arrivalDate
        let departure = clVisit.departureDate == .distantFuture ? nil : clVisit.departureDate

        Task { @MainActor in
            let place = await findOrCreatePlace(
                latitude: clVisit.coordinate.latitude,
                longitude: clVisit.coordinate.longitude,
                in: modelContext
            )

            if isDuplicate(place: place, arrival: arrival) {
                logger.info("Skipping duplicate CLVisit for \(place.name)")
                return
            }

            let visit = Visit(arrivalDate: arrival, departureDate: departure, place: place)
            modelContext.insert(visit)
            try? modelContext.save()

            currentVisit = visit
            onVisitRecorded?(visit)
            logger.notice("Recorded CLVisit at \(place.name)")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            logger.debug("didUpdateLocations called with empty array")
            return
        }

        logger.debug("Location update: (\(location.coordinate.latitude), \(location.coordinate.longitude)) accuracy: \(location.horizontalAccuracy)m")

        guard let modelContext else {
            logger.error("Location update ignored — modelContext is nil")
            return
        }

        userLocation = location.coordinate

        if let dwellLoc = dwellLocation {
            let distance = location.distance(from: dwellLoc)
            let elapsed = dwellStartDate.map { Int(Date().timeIntervalSince($0)) } ?? 0

            if distance < dwellRadiusMeters {
                logger.debug("Still within dwell radius (\(Int(distance))m < \(Int(self.dwellRadiusMeters))m), elapsed: \(elapsed)s")

                if let start = dwellStartDate,
                   Date().timeIntervalSince(start) >= dwellThresholdSeconds {
                    logger.notice("Dwell threshold met via location update — recording visit")
                    recordDwellVisit(at: dwellLoc, arrival: start, context: modelContext)
                }
            } else {
                logger.info("Moved outside dwell radius (\(Int(distance))m >= \(Int(self.dwellRadiusMeters))m) — resetting dwell")
                finalizeDwell()
                dwellLocation = location
                dwellStartDate = Date()
                logger.info("New dwell started at (\(location.coordinate.latitude), \(location.coordinate.longitude))")
            }
        } else {
            dwellLocation = location
            dwellStartDate = Date()
            logger.info("First location — dwell started at (\(location.coordinate.latitude), \(location.coordinate.longitude))")
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.error("Location error: \(error.localizedDescription)")
        if let clError = error as? CLError {
            logger.error("CLError code: \(clError.code.rawValue)")
        }
    }

    // MARK: - Dwell Visit Recording

    private func recordDwellVisit(at location: CLLocation, arrival: Date, context: ModelContext) {
        if let lastDwell = lastRecordedDwellLocation,
           location.distance(from: lastDwell) < dwellRadiusMeters {
            logger.debug("Dwell already recorded at this location — skipping")
            return
        }

        lastRecordedDwellLocation = location
        logger.notice("Recording dwell visit at (\(location.coordinate.latitude), \(location.coordinate.longitude)), arrived: \(arrival)")

        Task { @MainActor in
            let place = await findOrCreatePlace(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                in: context
            )

            if isDuplicate(place: place, arrival: arrival) {
                logger.info("Skipping duplicate dwell visit for \(place.name)")
                return
            }

            let visit = Visit(arrivalDate: arrival, departureDate: nil, place: place)
            context.insert(visit)
            try? context.save()

            currentVisit = visit
            onVisitRecorded?(visit)
            let stayMinutes = Int(Date().timeIntervalSince(arrival) / 60)
            logger.notice("VISIT RECORDED: \(place.name) (category: \(place.category ?? "none"), stayed \(stayMinutes) min)")
        }
    }

    private func finalizeDwell() {
        guard let dwellLoc = dwellLocation,
              let modelContext else {
            dwellLocation = nil
            dwellStartDate = nil
            return
        }

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
                    logger.notice("Finalized departure for \(place.name)")
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
        let threshold: TimeInterval = 600
        let isDup = place.visits.contains { visit in
            abs(visit.arrivalDate.timeIntervalSince(arrival)) < threshold
        }
        if isDup {
            logger.debug("Duplicate detected for \(place.name) near \(arrival)")
        }
        return isDup
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
            logger.debug("Found existing place: \(existing.name)")
            return existing
        }

        logger.info("No existing place within \(threshold) degrees — resolving name + category")
        let resolved = await resolvePlace(latitude: latitude, longitude: longitude)
        let place = Place(name: resolved.name, latitude: latitude, longitude: longitude, category: resolved.category, city: resolved.city, state: resolved.state)
        context.insert(place)
        logger.notice("Created new place: \(resolved.name) (category: \(resolved.category ?? "none"), city: \(resolved.city ?? "none"), state: \(resolved.state ?? "none"), source: \(resolved.source))")
        return place
    }

    // MARK: - Place Name + Category Resolution

    private struct ResolvedPlace {
        let name: String
        let category: String?
        let city: String?
        let state: String?
        let source: String  // "mapkit" or "geocoder"
    }

    /// Resolves a coordinate to a place name + category + city/state.
    /// 1. First tries MKLocalSearch to find a nearby business/POI (e.g. "Walmart", "Costco").
    /// 2. Falls back to CLGeocoder for an address if no POI is found.
    /// Always fetches city/state via reverse geocoding.
    private func resolvePlace(latitude: Double, longitude: Double) async -> ResolvedPlace {
        // Always fetch city/state from reverse geocoding
        let geoInfo = await reverseGeocodeDetails(latitude: latitude, longitude: longitude)

        // Step 1: Try to find a named business/POI via MapKit
        if let poi = await searchNearbyPOI(latitude: latitude, longitude: longitude) {
            return ResolvedPlace(name: poi.name, category: poi.category, city: geoInfo.city, state: geoInfo.state, source: poi.source)
        }

        // Step 2: Fall back to reverse geocoding for address + separate categorization
        let categoryResult = await PlaceCategorizer.categorize(latitude: latitude, longitude: longitude)
        return ResolvedPlace(name: geoInfo.name, category: categoryResult?.label, city: geoInfo.city, state: geoInfo.state, source: "geocoder")
    }

    /// Searches for the nearest named business/POI using coordinate-based search.
    /// Uses MKLocalPointsOfInterestRequest (no text query bias) with a 250m radius
    /// to handle large venues like Walmart, Costco, malls, etc.
    private func searchNearbyPOI(latitude: Double, longitude: Double) async -> ResolvedPlace? {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let targetLocation = CLLocation(latitude: latitude, longitude: longitude)
        let searchRadius: CLLocationDistance = 250 // meters — large enough for big-box stores

        // Use coordinate-based POI request — no text query, so no bias toward
        // specific business types. Returns all POIs within the radius.
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: searchRadius)
        request.pointOfInterestFilter = .includingAll

        let search = MKLocalSearch(request: request)

        do {
            let response = try await search.start()

            // Rank candidates by distance — closest named POI wins
            let candidates = response.mapItems
                .compactMap { item -> (item: MKMapItem, distance: CLLocationDistance, name: String)? in
                    guard let name = item.name, !name.isEmpty,
                          let itemLocation = item.placemark.location else { return nil }
                    let dist = itemLocation.distance(from: targetLocation)
                    guard dist <= searchRadius else { return nil }
                    return (item, dist, name)
                }
                .sorted { $0.distance < $1.distance }

            if let best = candidates.first {
                let category: String?
                if let poiCategory = best.item.pointOfInterestCategory,
                   let match = PlaceCategorizer.categoryMap.first(where: { $0.category == poiCategory }) {
                    category = match.label
                } else {
                    category = nil
                }

                logger.info("MapKit POI found: \(best.name) (\(Int(best.distance))m away, category: \(category ?? "none"))")

                // Log runner-up for debugging
                if candidates.count > 1 {
                    let runnerUp = candidates[1]
                    logger.debug("  runner-up: \(runnerUp.name) (\(Int(runnerUp.distance))m)")
                }

                return ResolvedPlace(name: best.name, category: category, city: nil, state: nil, source: "mapkit")
            }

            logger.debug("No MapKit POI within \(Int(searchRadius))m of (\(latitude), \(longitude))")
        } catch {
            logger.warning("MKLocalSearch failed: \(error.localizedDescription)")
        }

        return nil
    }

    private struct GeoDetails {
        let name: String
        let city: String?
        let state: String?
    }

    /// Reverse geocodes a coordinate to get name, city, and state.
    private func reverseGeocodeDetails(latitude: Double, longitude: Double) async -> GeoDetails {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                let name = placemark.name
                    ?? placemark.thoroughfare
                    ?? placemark.subLocality
                    ?? placemark.locality
                    ?? "Unknown Place"
                let city = placemark.locality
                let state = placemark.administrativeArea
                logger.debug("Reverse geocoded (\(latitude), \(longitude)) -> \(name), city: \(city ?? "nil"), state: \(state ?? "nil")")
                return GeoDetails(name: name, city: city, state: state)
            }
        } catch {
            logger.error("Geocoding failed: \(error.localizedDescription)")
        }
        return GeoDetails(name: "Unknown Place", city: nil, state: nil)
    }
}
