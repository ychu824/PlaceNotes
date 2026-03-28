import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.placenotes.app", category: "TrackingManager")

final class TrackingManager: ObservableObject {
    private let locationManager: LocationManager
    private let settings: AppSettings
    private var pauseTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    @Published var state: TrackingState

    init(locationManager: LocationManager, settings: AppSettings = .shared) {
        self.locationManager = locationManager
        self.settings = settings
        self.state = settings.trackingState
        logger.info("TrackingManager initialized, state: \(self.state.status.rawValue)")

        checkPauseExpiry()
    }

    func enableTracking() {
        logger.notice(">>> Enable tracking requested <<<")
        locationManager.requestAuthorization()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.state.status = .active
            self.state.pauseResumeDate = nil
            self.locationManager.startMonitoring()
            self.persist()
            logger.notice("Tracking enabled and monitoring started")
        }
    }

    func disableTracking() {
        logger.notice(">>> Disable tracking requested <<<")
        state.status = .disabled
        state.pauseResumeDate = nil
        locationManager.stopMonitoring()
        pauseTimer?.invalidate()
        persist()
        logger.notice("Tracking disabled")
    }

    func pauseTracking(for duration: PauseDuration) {
        logger.notice(">>> Pause tracking for \(duration.label) <<<")
        state.status = .paused
        state.pauseResumeDate = Date().addingTimeInterval(duration.interval)
        locationManager.stopMonitoring()
        schedulePauseResume(after: duration.interval)
        persist()
    }

    func resumeTracking() {
        logger.notice(">>> Resume tracking <<<")
        state.status = .active
        state.pauseResumeDate = nil
        pauseTimer?.invalidate()
        locationManager.startMonitoring()
        persist()
        logger.notice("Tracking resumed")
    }

    // MARK: - Private

    private func schedulePauseResume(after interval: TimeInterval) {
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            logger.info("Pause timer fired — auto-resuming")
            self?.resumeTracking()
        }
    }

    private func checkPauseExpiry() {
        if state.status == .paused, let resumeDate = state.pauseResumeDate {
            if Date() >= resumeDate {
                logger.info("Pause expired during app launch — resuming")
                resumeTracking()
            } else {
                let remaining = resumeDate.timeIntervalSince(Date())
                logger.info("Pause still active — \(Int(remaining))s remaining")
                schedulePauseResume(after: remaining)
                locationManager.stopMonitoring()
            }
        } else if state.status == .active {
            logger.info("State is active on launch — starting monitoring")
            locationManager.startMonitoring()
        } else {
            logger.info("State is disabled on launch — not starting monitoring")
        }
    }

    private func persist() {
        settings.trackingState = state
    }
}
