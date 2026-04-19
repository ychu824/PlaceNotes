import Foundation
import CoreLocation
import MapKit
import SwiftData
import os

private let logger = Logger(subsystem: "com.placenotes.app", category: "LocationManager")

// MARK: - Location Sample

/// A single GPS sample collected during a potential stay.
struct LocationSample {
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let horizontalAccuracy: CLLocationAccuracy
    let speed: CLLocationSpeed
}

// MARK: - Stay Cluster

/// A cluster of location samples representing a detected stay.
struct StayCluster {
    let samples: [LocationSample]
    let center: CLLocationCoordinate2D
    let startDate: Date
    let medianAccuracy: Double
    let spreadMeters: Double

    /// Whether the cluster is too spread out to reliably resolve to a single place.
    var isAmbiguous: Bool { spreadMeters > 100 }
}

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let clManager = CLLocationManager()
    private var modelContext: ModelContext?

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var currentVisit: Visit?
    @Published var userLocation: CLLocationCoordinate2D?

    var onVisitRecorded: ((Visit) -> Void)?

    // MARK: - Dwell detection

    /// Raw samples collected at the current candidate stay location.
    private var dwellSamples: [LocationSample] = []
    private var dwellStartDate: Date?
    private var lastRecordedDwellLocation: CLLocation?
    private var dwellTimer: Timer?
    private let settings: AppSettings

    /// Distance (meters) the user must move before we consider them "left".
    private let dwellRadiusMeters: Double = 80

    /// Maximum horizontal accuracy to accept a sample (meters).
    /// Samples noisier than this are dropped.
    private let maxAcceptableAccuracy: CLLocationAccuracy = 65

    /// Maximum speed (m/s) to accept a sample. ~3.6 km/h — faster means walking/driving, not staying.
    private let maxStationarySpeed: CLLocationSpeed = 2.0

    /// Minimum dwell time to create a place (seconds). Hard floor regardless of settings.
    private let minimumDwellSeconds: TimeInterval = 300 // 5 minutes

    /// Maximum accuracy to attempt venue labeling. Beyond this, fall back to address.
    private let maxAccuracyForVenueLabel: CLLocationAccuracy = StayDetector.maxAccuracyForVenueLabel

    /// Seconds the user must remain stationary to trigger a dwell visit.
    private var dwellThresholdSeconds: TimeInterval {
        max(minimumDwellSeconds, TimeInterval(settings.minStayMinutes * 60))
    }

    init(settings: AppSettings = .shared) {
        self.settings = settings
        super.init()
        clManager.delegate = self
        clManager.allowsBackgroundLocationUpdates = true
        clManager.pausesLocationUpdatesAutomatically = false
        clManager.desiredAccuracy = kCLLocationAccuracyBest
        clManager.distanceFilter = 10
        authorizationStatus = clManager.authorizationStatus
        logger.info("LocationManager initialized, auth status: \(self.authorizationStatus.rawValue), minStay: \(settings.minStayMinutes)min")
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        logger.info("ModelContext configured")
        cleanupStaleRawSamples(context: modelContext)
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

    private func startDwellTimer() {
        dwellTimer?.invalidate()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkDwellStatus()
        }
        logger.debug("Dwell timer started (30s interval)")
    }

    private func checkDwellStatus() {
        guard !dwellSamples.isEmpty,
              let start = dwellStartDate,
              let modelContext else {
            logger.debug("Dwell timer tick — no active dwell samples")
            return
        }

        let elapsed = Date().timeIntervalSince(start)
        let threshold = dwellThresholdSeconds
        if elapsed >= threshold {
            logger.notice("Dwell threshold reached via timer (\(Int(elapsed))s >= \(Int(threshold))s) — recording visit")
            let cluster = buildCluster(from: dwellSamples, startDate: start)
            recordDwellVisit(cluster: cluster, context: modelContext)
        } else {
            let remaining = Int(threshold - elapsed)
            logger.info("Dwell timer tick — \(remaining)s remaining, \(self.dwellSamples.count) samples collected")
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
        logger.info("  arrival: \(clVisit.arrivalDate), departure: \(clVisit.departureDate == .distantFuture ? "still here" : "\(clVisit.departureDate)")")
        logger.info("  horizontalAccuracy: \(clVisit.horizontalAccuracy)m")

        guard clVisit.arrivalDate != .distantPast else {
            logger.warning("CLVisit ignored — arrivalDate is distantPast (unknown arrival)")
            return
        }

        guard let modelContext else {
            logger.error("CLVisit ignored — modelContext is nil")
            return
        }

        let arrival = clVisit.arrivalDate
        let departure = clVisit.departureDate == .distantFuture ? nil : clVisit.departureDate

        // Check minimum dwell time for CLVisit
        if let dep = departure {
            let dwell = dep.timeIntervalSince(arrival)
            if dwell < minimumDwellSeconds {
                logger.info("CLVisit ignored — dwell too short (\(Int(dwell))s < \(Int(self.minimumDwellSeconds))s)")
                return
            }
        }

        // Determine confidence from CLVisit's accuracy
        let accuracy = clVisit.horizontalAccuracy
        let dwellSeconds = departure.map { $0.timeIntervalSince(arrival) }
        let confidence = computeConfidence(accuracy: accuracy, dwellSeconds: dwellSeconds, clusterSpread: nil)
        let useAddressFallback = accuracy > maxAccuracyForVenueLabel || confidence == .low

        Task { @MainActor in
            let (place, alternatives) = await findOrCreatePlace(
                latitude: clVisit.coordinate.latitude,
                longitude: clVisit.coordinate.longitude,
                in: modelContext,
                addressOnly: useAddressFallback
            )

            if isDuplicate(place: place, arrival: arrival) {
                logger.info("Skipping duplicate CLVisit for \(place.name)")
                return
            }

            let visit = Visit(arrivalDate: arrival, departureDate: departure, place: place)
            visit.alternativePlaces = alternatives
            visit.confidence = confidence
            visit.medianAccuracyMeters = accuracy
            modelContext.insert(visit)
            try? modelContext.save()

            currentVisit = visit
            onVisitRecorded?(visit)
            logger.notice("Recorded CLVisit at \(place.name) (confidence: \(confidence.rawValue), accuracy: \(Int(accuracy))m)")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            logger.debug("didUpdateLocations called with empty array")
            return
        }

        logger.debug("Location update: (\(location.coordinate.latitude), \(location.coordinate.longitude)) accuracy: \(location.horizontalAccuracy)m speed: \(location.speed)m/s")

        guard let modelContext else {
            logger.error("Location update ignored — modelContext is nil")
            return
        }

        userLocation = location.coordinate

        // Step 1: Filter noisy / stale samples
        let isAccurate = location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= maxAcceptableAccuracy
        let isStationary = location.speed < 0 || location.speed <= maxStationarySpeed // speed < 0 means unknown
        let isRecent = abs(location.timestamp.timeIntervalSinceNow) < 30 // not stale

        if !isAccurate {
            logger.debug("Sample dropped — accuracy \(location.horizontalAccuracy)m > \(self.maxAcceptableAccuracy)m threshold")
        }
        if !isStationary {
            logger.debug("Sample dropped — speed \(location.speed)m/s > \(self.maxStationarySpeed)m/s threshold")
        }

        let filterStatus: String
        if !isAccurate {
            filterStatus = "rejected-accuracy"
        } else if !isStationary {
            filterStatus = "rejected-speed"
        } else {
            filterStatus = "accepted"
        }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let ts = location.timestamp
        let hAcc = location.horizontalAccuracy
        let spd = location.speed
        let alt = location.altitude
        let vAcc = location.verticalAccuracy
        let crs = location.course >= 0 ? location.course : nil

        Task { @MainActor [weak self] in
            guard let ctx = self?.modelContext else { return }
            let raw = RawLocationSample(
                latitude: lat, longitude: lon, timestamp: ts,
                horizontalAccuracy: hAcc, speed: spd,
                altitude: alt, verticalAccuracy: vAcc, course: crs,
                filterStatus: filterStatus
            )
            ctx.insert(raw)
        }

        let sample = LocationSample(
            coordinate: location.coordinate,
            timestamp: location.timestamp,
            horizontalAccuracy: location.horizontalAccuracy,
            speed: location.speed
        )

        if !dwellSamples.isEmpty {
            // Calculate distance from the centroid of existing samples for stability
            let currentCenter = weightedCenter(of: dwellSamples)
            let centerLocation = CLLocation(latitude: currentCenter.latitude, longitude: currentCenter.longitude)
            let distance = location.distance(from: centerLocation)

            if distance < dwellRadiusMeters {
                // Still within dwell radius — collect sample if quality is good
                if isAccurate && isStationary && isRecent {
                    dwellSamples.append(sample)
                    logger.debug("Sample collected (\(self.dwellSamples.count) total), \(Int(distance))m from center")
                }

                if let start = dwellStartDate,
                   Date().timeIntervalSince(start) >= dwellThresholdSeconds {
                    logger.notice("Dwell threshold met via location update — recording visit")
                    let cluster = buildCluster(from: dwellSamples, startDate: start)
                    recordDwellVisit(cluster: cluster, context: modelContext)
                }
            } else {
                logger.info("Moved outside dwell radius (\(Int(distance))m >= \(Int(self.dwellRadiusMeters))m) — resetting dwell")
                finalizeDwell()
                // Start new dwell only if this sample is good
                if isAccurate && isStationary && isRecent {
                    dwellSamples = [sample]
                    dwellStartDate = Date()
                    logger.info("New dwell started at (\(location.coordinate.latitude), \(location.coordinate.longitude))")
                }
            }
        } else {
            // No dwell in progress — start one if sample is good
            if isAccurate && isStationary && isRecent {
                dwellSamples = [sample]
                dwellStartDate = Date()
                logger.info("First location — dwell started at (\(location.coordinate.latitude), \(location.coordinate.longitude))")
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.error("Location error: \(error.localizedDescription)")
        if let clError = error as? CLError {
            logger.error("CLError code: \(clError.code.rawValue)")
        }
    }

    // MARK: - Raw Sample Retention

    private func cleanupStaleRawSamples(context: ModelContext) {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -settings.rawLocationRetentionDays,
            to: Date()
        ) ?? Date()

        Task { @MainActor in
            let descriptor = FetchDescriptor<RawLocationSample>(
                predicate: #Predicate { $0.timestamp < cutoff }
            )
            let stale = (try? context.fetch(descriptor)) ?? []
            for sample in stale {
                context.delete(sample)
            }
            if !stale.isEmpty {
                try? context.save()
                logger.info("Deleted \(stale.count) raw samples older than \(self.settings.rawLocationRetentionDays) days")
            }
        }
    }

    // MARK: - Cluster Building (delegates to StayDetector)

    private func weightedCenter(of samples: [LocationSample]) -> CLLocationCoordinate2D {
        StayDetector.weightedCenter(of: samples)
    }

    private func buildCluster(from samples: [LocationSample], startDate: Date) -> StayCluster {
        let cluster = StayDetector.buildCluster(from: samples, startDate: startDate)
        logger.info("Cluster built: center=(\(cluster.center.latitude), \(cluster.center.longitude)), \(samples.count) samples, spread=\(Int(cluster.spreadMeters))m, medianAccuracy=\(Int(cluster.medianAccuracy))m")
        return cluster
    }

    private func computeConfidence(accuracy: Double, dwellSeconds: TimeInterval?, clusterSpread: Double?) -> PlaceConfidence {
        StayDetector.computeConfidence(accuracy: accuracy, dwellSeconds: dwellSeconds, clusterSpread: clusterSpread)
    }

    // MARK: - Dwell Visit Recording

    private func recordDwellVisit(cluster: StayCluster, context: ModelContext) {
        let clusterCenter = CLLocation(latitude: cluster.center.latitude, longitude: cluster.center.longitude)

        if let lastDwell = lastRecordedDwellLocation,
           clusterCenter.distance(from: lastDwell) < dwellRadiusMeters {
            logger.debug("Dwell already recorded at this location — skipping")
            return
        }

        // Don't create place if dwell is too short
        let elapsed = Date().timeIntervalSince(cluster.startDate)
        if elapsed < minimumDwellSeconds {
            logger.info("Dwell too short (\(Int(elapsed))s < \(Int(self.minimumDwellSeconds))s) — not recording")
            return
        }

        lastRecordedDwellLocation = clusterCenter

        let confidence = computeConfidence(
            accuracy: cluster.medianAccuracy,
            dwellSeconds: elapsed,
            clusterSpread: cluster.spreadMeters
        )
        let useAddressFallback = cluster.medianAccuracy > maxAccuracyForVenueLabel || cluster.isAmbiguous || confidence == .low

        logger.notice("Recording dwell visit: center=(\(cluster.center.latitude), \(cluster.center.longitude)), \(cluster.samples.count) samples, confidence=\(confidence.rawValue), addressOnly=\(useAddressFallback)")

        Task { @MainActor in
            let (place, alternatives) = await findOrCreatePlace(
                latitude: cluster.center.latitude,
                longitude: cluster.center.longitude,
                in: context,
                addressOnly: useAddressFallback
            )

            if isDuplicate(place: place, arrival: cluster.startDate) {
                logger.info("Skipping duplicate dwell visit for \(place.name)")
                return
            }

            let visit = Visit(arrivalDate: cluster.startDate, departureDate: nil, place: place)
            visit.alternativePlaces = alternatives
            visit.confidence = confidence
            visit.medianAccuracyMeters = cluster.medianAccuracy
            context.insert(visit)
            try? context.save()

            currentVisit = visit
            onVisitRecorded?(visit)
            let stayMinutes = Int(elapsed / 60)
            logger.notice("VISIT RECORDED: \(place.name) (confidence: \(confidence.rawValue), accuracy: \(Int(cluster.medianAccuracy))m, spread: \(Int(cluster.spreadMeters))m, stayed \(stayMinutes) min)")
        }
    }

    private func finalizeDwell() {
        guard !dwellSamples.isEmpty,
              let modelContext else {
            dwellSamples = []
            dwellStartDate = nil
            return
        }

        // Use cluster center for more accurate departure matching
        let center = weightedCenter(of: dwellSamples)
        let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)

        Task { @MainActor in
            let descriptor = FetchDescriptor<Visit>(
                predicate: #Predicate { $0.departureDate == nil },
                sortBy: [SortDescriptor(\.arrivalDate, order: .reverse)]
            )
            if let activeVisit = try? modelContext.fetch(descriptor).first,
               let place = activeVisit.place {
                let placeLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
                if centerLoc.distance(from: placeLocation) < dwellRadiusMeters {
                    activeVisit.departureDate = Date()
                    try? modelContext.save()
                    logger.notice("Finalized departure for \(place.name)")
                }
            }
        }

        dwellSamples = []
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
    private func findOrCreatePlace(latitude: Double, longitude: Double, in context: ModelContext, addressOnly: Bool = false) async -> (place: Place, alternatives: [PlaceCandidate]) {
        let threshold = 0.0005 // ~50 meters

        let minLat = latitude - threshold
        let maxLat = latitude + threshold
        let minLon = longitude - threshold
        let maxLon = longitude + threshold
        let descriptor = FetchDescriptor<Place>(
            predicate: #Predicate<Place> {
                $0.latitude >= minLat && $0.latitude <= maxLat &&
                $0.longitude >= minLon && $0.longitude <= maxLon
            }
        )
        let nearbyPlaces = (try? context.fetch(descriptor)) ?? []

        if let existing = nearbyPlaces.first {
            logger.debug("Found existing place: \(existing.name)")
            return (existing, [])
        }

        logger.info("No existing place within \(threshold) degrees — resolving (addressOnly: \(addressOnly))")
        let resolved = await resolvePlace(latitude: latitude, longitude: longitude, addressOnly: addressOnly)
        let place = Place(name: resolved.name, latitude: latitude, longitude: longitude, category: resolved.category, city: resolved.city, state: resolved.state)
        context.insert(place)
        logger.notice("Created new place: \(resolved.name) (category: \(resolved.category ?? "none"), city: \(resolved.city ?? "none"), source: \(resolved.source))")
        return (place, resolved.alternatives)
    }

    // MARK: - Place Name + Category Resolution

    private struct ResolvedPlace {
        let name: String
        let category: String?
        let city: String?
        let state: String?
        let source: String  // "mapkit", "geocoder", or "address-fallback"
        var alternatives: [PlaceCandidate] = []
    }

    /// Resolves a coordinate to a place name + category + city/state.
    /// When `addressOnly` is true (low confidence), skips POI search and returns address.
    private func resolvePlace(latitude: Double, longitude: Double, addressOnly: Bool = false) async -> ResolvedPlace {
        let geoInfo = await reverseGeocodeDetails(latitude: latitude, longitude: longitude)

        if addressOnly {
            logger.info("Address-only fallback: \(geoInfo.name)")
            return ResolvedPlace(name: geoInfo.name, category: nil, city: geoInfo.city, state: geoInfo.state, source: "address-fallback")
        }

        // Try to find a named business/POI via MapKit
        if let poi = await searchNearbyPOI(latitude: latitude, longitude: longitude, geoInfo: geoInfo) {
            return ResolvedPlace(name: poi.name, category: poi.category, city: geoInfo.city, state: geoInfo.state, source: poi.source, alternatives: poi.alternatives)
        }

        // Fall back to reverse geocoding + categorization
        let categoryResult = await PlaceCategorizer.categorize(latitude: latitude, longitude: longitude)
        return ResolvedPlace(name: geoInfo.name, category: categoryResult?.label, city: geoInfo.city, state: geoInfo.state, source: "geocoder")
    }

    /// Searches for the nearest named business/POI using coordinate-based search.
    /// Search radius scales with accuracy — tighter accuracy means smaller, more precise search.
    private func searchNearbyPOI(latitude: Double, longitude: Double, geoInfo: GeoDetails? = nil) async -> ResolvedPlace? {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let targetLocation = CLLocation(latitude: latitude, longitude: longitude)
        // Scale search radius: use 150m for precise locations, up to 250m max
        let searchRadius: CLLocationDistance = 150

        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: searchRadius)
        request.pointOfInterestFilter = .includingAll

        let search = MKLocalSearch(request: request)

        do {
            let response = try await search.start()

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

                let altGeoInfo: GeoDetails
                if let geoInfo {
                    altGeoInfo = geoInfo
                } else {
                    altGeoInfo = await reverseGeocodeDetails(latitude: latitude, longitude: longitude)
                }
                let alternatives: [PlaceCandidate] = Array(candidates.dropFirst().prefix(2)).map { candidate in
                    let altCategory: String?
                    if let poiCat = candidate.item.pointOfInterestCategory,
                       let match = PlaceCategorizer.categoryMap.first(where: { $0.category == poiCat }) {
                        altCategory = match.label
                    } else {
                        altCategory = nil
                    }
                    let altLat = candidate.item.placemark.coordinate.latitude
                    let altLon = candidate.item.placemark.coordinate.longitude
                    return PlaceCandidate(
                        name: candidate.name,
                        latitude: altLat,
                        longitude: altLon,
                        category: altCategory,
                        city: altGeoInfo.city,
                        state: altGeoInfo.state,
                        distanceMeters: candidate.distance
                    )
                }

                if !alternatives.isEmpty {
                    logger.info("  alternatives: \(alternatives.map { "\($0.name) (\(Int($0.distanceMeters))m)" })")
                }

                return ResolvedPlace(name: best.name, category: category, city: nil, state: nil, source: "mapkit", alternatives: alternatives)
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
