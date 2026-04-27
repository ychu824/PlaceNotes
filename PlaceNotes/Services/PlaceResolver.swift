import Foundation
import CoreLocation
import MapKit
import SwiftData
import os

private let logger = Logger(subsystem: "com.placenotes.app", category: "PlaceResolver")

private struct ResolvedPlace {
    let name: String
    let category: String?
    let city: String?
    let state: String?
    let source: String
    var alternatives: [PlaceCandidate] = []
}

private struct GeoDetails {
    let name: String
    let city: String?
    let state: String?
}

enum PlaceResolver {

    /// ~50 meters in degrees latitude/longitude. Used for nearest-existing-place matching.
    private static let nearbyThresholdDegrees: Double = 0.0005

    /// Network calls to CLGeocoder / MKLocalSearch are rate-limited by Apple and have no
    /// client-side timeout. On flaky networks they can stall for minutes — bound them.
    private static let networkTimeoutSeconds: TimeInterval = 8

    private static func timed<T: Sendable>(
        _ seconds: TimeInterval,
        _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    /// Returns the nearest Place within ~50m of the given coordinate, if any exists.
    @MainActor
    static func nearestExisting(latitude: Double, longitude: Double, in context: ModelContext) -> Place? {
        let minLat = latitude - nearbyThresholdDegrees
        let maxLat = latitude + nearbyThresholdDegrees
        let minLon = longitude - nearbyThresholdDegrees
        let maxLon = longitude + nearbyThresholdDegrees
        let descriptor = FetchDescriptor<Place>(
            predicate: #Predicate<Place> {
                $0.latitude >= minLat && $0.latitude <= maxLat &&
                $0.longitude >= minLon && $0.longitude <= maxLon
            }
        )
        return (try? context.fetch(descriptor))?.first
    }

    /// Full resolve: nearest-existing → geocode + POI search → create + insert new Place.
    @MainActor
    static func findOrCreate(
        latitude: Double,
        longitude: Double,
        in context: ModelContext,
        addressOnly: Bool = false
    ) async -> (place: Place, alternatives: [PlaceCandidate]) {
        if let existing = nearestExisting(latitude: latitude, longitude: longitude, in: context) {
            logger.debug("Found existing place: \(existing.name)")
            return (existing, [])
        }
        logger.info("No existing place within \(nearbyThresholdDegrees) degrees — resolving (addressOnly: \(addressOnly))")
        let resolved = await resolve(latitude: latitude, longitude: longitude, addressOnly: addressOnly)
        let place = Place(
            name: resolved.name,
            latitude: latitude,
            longitude: longitude,
            category: resolved.category,
            city: resolved.city,
            state: resolved.state
        )
        context.insert(place)
        logger.notice("Created new place: \(resolved.name) (category: \(resolved.category ?? "none"), city: \(resolved.city ?? "none"), source: \(resolved.source))")
        return (place, resolved.alternatives)
    }

    // MARK: - Private

    private static func resolve(latitude: Double, longitude: Double, addressOnly: Bool) async -> ResolvedPlace {
        let geoInfo = await reverseGeocodeDetails(latitude: latitude, longitude: longitude)
        if addressOnly {
            logger.info("Address-only fallback: \(geoInfo.name)")
            return ResolvedPlace(name: geoInfo.name, category: nil, city: geoInfo.city, state: geoInfo.state, source: "address-fallback")
        }
        if let poi = await searchNearbyPOI(latitude: latitude, longitude: longitude, geoInfo: geoInfo) {
            return ResolvedPlace(name: poi.name, category: poi.category, city: geoInfo.city, state: geoInfo.state, source: poi.source, alternatives: poi.alternatives)
        }
        let categoryResult = await PlaceCategorizer.categorize(latitude: latitude, longitude: longitude)
        return ResolvedPlace(name: geoInfo.name, category: categoryResult?.label, city: geoInfo.city, state: geoInfo.state, source: "geocoder")
    }

    private static func searchNearbyPOI(latitude: Double, longitude: Double, geoInfo: GeoDetails?) async -> ResolvedPlace? {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let targetLocation = CLLocation(latitude: latitude, longitude: longitude)
        let searchRadius: CLLocationDistance = 150

        let response: MKLocalSearch.Response? = await timed(networkTimeoutSeconds) {
            let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: searchRadius)
            request.pointOfInterestFilter = .includingAll
            let search = MKLocalSearch(request: request)
            return try? await search.start()
        }

        guard let response else {
            logger.warning("MKLocalSearch timed out or failed at (\(latitude), \(longitude))")
            return nil
        }

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
            let category: String? = {
                if let poiCategory = best.item.pointOfInterestCategory,
                   let match = PlaceCategorizer.categoryMap.first(where: { $0.category == poiCategory }) {
                    return match.label
                }
                return nil
            }()

            logger.info("MapKit POI found: \(best.name) (\(Int(best.distance))m away, category: \(category ?? "none"))")

            let altGeoInfo: GeoDetails
            if let geoInfo {
                altGeoInfo = geoInfo
            } else {
                altGeoInfo = await reverseGeocodeDetails(latitude: latitude, longitude: longitude)
            }
            let alternatives: [PlaceCandidate] = Array(candidates.dropFirst().prefix(2)).map { candidate in
                let altCategory: String? = {
                    if let poiCat = candidate.item.pointOfInterestCategory,
                       let match = PlaceCategorizer.categoryMap.first(where: { $0.category == poiCat }) {
                        return match.label
                    }
                    return nil
                }()
                return PlaceCandidate(
                    name: candidate.name,
                    latitude: candidate.item.placemark.coordinate.latitude,
                    longitude: candidate.item.placemark.coordinate.longitude,
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
        return nil
    }

    private static func reverseGeocodeDetails(latitude: Double, longitude: Double) async -> GeoDetails {
        let placemarks: [CLPlacemark]? = await timed(networkTimeoutSeconds) {
            let geocoder = CLGeocoder()
            let location = CLLocation(latitude: latitude, longitude: longitude)
            return try? await geocoder.reverseGeocodeLocation(location)
        }
        if let placemark = placemarks?.first {
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
        if placemarks == nil {
            logger.warning("Reverse geocoding timed out or failed (\(latitude), \(longitude))")
        }
        return GeoDetails(name: "Unknown Place", city: nil, state: nil)
    }
}
