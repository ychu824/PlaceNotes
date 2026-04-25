import Foundation
import CoreLocation
import SwiftData
import os

private let logger = Logger(subsystem: "com.placenotes.app", category: "QuickCaptureService")

enum QuickCaptureResult {
    case newVisit(visitID: UUID, placeName: String, journalEntryID: UUID)
    case merged(intoVisitID: UUID, placeName: String, journalEntryID: UUID)
}

enum QuickCaptureError: Error {
    case noLocation
    case placeNotResolved
}

enum QuickCaptureService {

    /// Max accuracy (meters) to trust a live GPS fix. Beyond this, fall through to EXIF.
    /// Matches the 50m nearest-place radius in PlaceResolver — if accuracy exceeds the
    /// matching radius, a "nearest" lookup could mis-attribute across neighbors.
    static let liveFixAccuracyThreshold: CLLocationDistance = 50

    /// Resolves the coordinate for a quick capture per D1 priority:
    /// 1. live fix if accuracy ≤ 50m
    /// 2. EXIF location from the saved PHAsset
    /// 3. nil (caller opens ManualPlacePickerView)
    static func resolveCoordinate(liveFix: CLLocation?, exifLocation: CLLocation?) -> CLLocation? {
        if let live = liveFix,
           live.horizontalAccuracy >= 0,
           live.horizontalAccuracy <= liveFixAccuracyThreshold {
            return live
        }
        return exifLocation
    }
}

extension QuickCaptureService {

    static let mergeWindow: TimeInterval = 30 * 60

    enum MergeDecision: Equatable {
        case mergeWith(visitID: UUID)
        case createNew
    }

    static func mergeDecision(for place: Place, now: Date) -> MergeDecision {
        let cutoff = now.addingTimeInterval(-mergeWindow)
        let candidate = place.visits
            .filter { visit in
                if visit.departureDate == nil { return true }
                return (visit.departureDate ?? .distantPast) > cutoff
            }
            .sorted { $0.arrivalDate > $1.arrivalDate }
            .first
        if let c = candidate {
            return .mergeWith(visitID: c.id)
        }
        return .createNew
    }
}

extension QuickCaptureService {

    static let quickVisitDuration: TimeInterval = 60

    @MainActor
    static func logCapture(
        coordinate: CLLocation,
        photoAssetId: String,
        now: Date = Date(),
        in context: ModelContext
    ) async -> QuickCaptureResult {
        let (place, _) = await PlaceResolver.findOrCreate(
            latitude: coordinate.coordinate.latitude,
            longitude: coordinate.coordinate.longitude,
            in: context
        )

        let entry = JournalEntry(date: now, photoAssetIdentifiers: [photoAssetId])
        entry.place = place
        context.insert(entry)

        switch mergeDecision(for: place, now: now) {
        case .mergeWith(let visitID):
            try? context.save()
            return .merged(intoVisitID: visitID, placeName: place.displayName, journalEntryID: entry.id)

        case .createNew:
            let visit = Visit(
                arrivalDate: now,
                departureDate: now.addingTimeInterval(quickVisitDuration),
                place: place
            )
            visit.confidence = .high
            context.insert(visit)
            try? context.save()
            return .newVisit(visitID: visit.id, placeName: place.displayName, journalEntryID: entry.id)
        }
    }
}
