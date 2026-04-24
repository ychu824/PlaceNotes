import Foundation
import CoreLocation
import MapKit
import SwiftData
import os

private let logger = Logger(subsystem: "com.placenotes.app", category: "PlaceResolver")

struct ResolvedPlace {
    let name: String
    let category: String?
    let city: String?
    let state: String?
    let source: String
    var alternatives: [PlaceCandidate] = []
}

struct GeoDetails {
    let name: String
    let city: String?
    let state: String?
}

enum PlaceResolver {

    /// Returns the nearest Place within ~50m of the given coordinate, if any exists.
    @MainActor
    static func nearestExisting(latitude: Double, longitude: Double, in context: ModelContext) -> Place? {
        let threshold = 0.0005 // ~50m
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
        logger.notice("Created new place: \(resolved.name) (source: \(resolved.source))")
        return (place, resolved.alternatives)
    }

    // MARK: - Private

    private static func resolve(latitude: Double, longitude: Double, addressOnly: Bool) async -> ResolvedPlace {
        let geoInfo = await reverseGeocodeDetails(latitude: latitude, longitude: longitude)
        if addressOnly {
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

            guard let best = candidates.first else { return nil }

            let category: String? = {
                if let poiCategory = best.item.pointOfInterestCategory,
                   let match = PlaceCategorizer.categoryMap.first(where: { $0.category == poiCategory }) {
                    return match.label
                }
                return nil
            }()

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

            return ResolvedPlace(name: best.name, category: category, city: nil, state: nil, source: "mapkit", alternatives: alternatives)
        } catch {
            logger.warning("MKLocalSearch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func reverseGeocodeDetails(latitude: Double, longitude: Double) async -> GeoDetails {
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
                return GeoDetails(name: name, city: placemark.locality, state: placemark.administrativeArea)
            }
        } catch {
            logger.error("Geocoding failed: \(error.localizedDescription)")
        }
        return GeoDetails(name: "Unknown Place", city: nil, state: nil)
    }
}
