import Foundation
import CoreLocation
import Combine
import SwiftData
import UIKit
import os

private let logger = Logger(subsystem: "com.placenotes.app", category: "QuickCaptureViewModel")

@MainActor
final class QuickCaptureViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case acquiringLocation
        case savingPhoto
        case resolvingPlace
        case manualPickNeeded
        case done(ToastPayload)
        case error(String)
    }

    struct ToastPayload: Equatable {
        enum Kind: Equatable { case newVisit, merged }
        let kind: Kind
        let placeName: String
        let visitID: UUID
        let journalEntryID: UUID
    }

    @Published private(set) var state: State = .idle
    @Published var showCamera: Bool = false
    @Published private(set) var pendingPhotoAssetId: String?

    private let oneShot: LocationOneShotProviding
    private let context: ModelContext
    private var pendingLiveFix: CLLocation?

    init(oneShot: LocationOneShotProviding, context: ModelContext) {
        self.oneShot = oneShot
        self.context = context
    }

    // MARK: - Flow

    func beginCapture() {
        guard state == .idle else { return }
        state = .acquiringLocation
        showCamera = true
        Task { [weak self] in
            guard let self else { return }
            let loc = await self.oneShot.fetchOnce(timeout: 5)
            await MainActor.run { self.pendingLiveFix = loc }
        }
    }

    func photoCaptured(image: UIImage, exifLocation: CLLocation?) {
        state = .savingPhoto
        Task { [weak self] in
            guard let self else { return }
            guard let filename = PhotoStorage.saveImage(image) else {
                logger.error("PhotoStorage.saveImage returned nil")
                await MainActor.run { self.state = .error("Couldn't save photo to disk.") }
                return
            }
            await self.continueAfterPhoto(photoAssetId: filename, exifLocation: exifLocation)
        }
    }

    func cancelCapture() {
        pendingLiveFix = nil
        pendingPhotoAssetId = nil
        showCamera = false
        state = .idle
    }

    func manualPlaceSelected(_ place: Place, photoAssetId: String) {
        state = .resolvingPlace
        Task { [weak self] in
            guard let self else { return }
            let result = await QuickCaptureService.logCapture(
                coordinate: CLLocation(latitude: place.latitude, longitude: place.longitude),
                photoAssetId: photoAssetId,
                in: self.context
            )
            await MainActor.run { self.state = .done(self.toast(from: result)) }
        }
    }

    func undoNewVisit(_ payload: ToastPayload) {
        let journalEntryID = payload.journalEntryID
        let visitID = payload.visitID
        let entryDesc = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.id == journalEntryID })
        let visitDesc = FetchDescriptor<Visit>(predicate: #Predicate { $0.id == visitID })
        if let entry = (try? context.fetch(entryDesc))?.first { context.delete(entry) }
        if let visit = (try? context.fetch(visitDesc))?.first { context.delete(visit) }
        try? context.save()
        state = .idle
    }

    func splitFromMerge(_ payload: ToastPayload) {
        let journalEntryID = payload.journalEntryID
        let entryDesc = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.id == journalEntryID })
        guard let entry = (try? context.fetch(entryDesc))?.first, let place = entry.place else {
            state = .idle
            return
        }
        let now = Date()
        let visit = Visit(
            arrivalDate: now,
            departureDate: now.addingTimeInterval(QuickCaptureService.quickVisitDuration),
            place: place
        )
        visit.confidence = .high
        context.insert(visit)
        try? context.save()
        state = .idle
    }

    // MARK: - Private

    private func continueAfterPhoto(photoAssetId: String, exifLocation: CLLocation?) async {
        let coord = QuickCaptureService.resolveCoordinate(liveFix: pendingLiveFix, exifLocation: exifLocation)
        guard let coord else {
            await MainActor.run {
                self.pendingPhotoAssetId = photoAssetId
                self.state = .manualPickNeeded
            }
            return
        }
        await MainActor.run { self.state = .resolvingPlace }
        let result = await QuickCaptureService.logCapture(
            coordinate: coord,
            photoAssetId: photoAssetId,
            in: context
        )
        await MainActor.run { self.state = .done(self.toast(from: result)) }
    }

    private func toast(from result: QuickCaptureResult) -> ToastPayload {
        switch result {
        case .newVisit(let vid, let name, let eid):
            return ToastPayload(kind: .newVisit, placeName: name, visitID: vid, journalEntryID: eid)
        case .merged(let vid, let name, let eid):
            return ToastPayload(kind: .merged, placeName: name, visitID: vid, journalEntryID: eid)
        }
    }

}
