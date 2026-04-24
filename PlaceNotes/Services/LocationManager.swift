import Foundation
import CoreLocation
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
            let (place, alternatives) = await PlaceResolver.findOrCreate(
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
            let (place, alternatives) = await PlaceResolver.findOrCreate(
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

}
