import Foundation
import Combine

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

        // Auto-resume when pause expires
        checkPauseExpiry()
    }

    func enableTracking() {
        locationManager.requestAuthorization()

        // Small delay to let the authorization dialog complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.state.status = .active
            self.state.pauseResumeDate = nil
            self.locationManager.startMonitoring()
            self.persist()
        }
    }

    func disableTracking() {
        state.status = .disabled
        state.pauseResumeDate = nil
        locationManager.stopMonitoring()
        pauseTimer?.invalidate()
        persist()
    }

    func pauseTracking(for duration: PauseDuration) {
        state.status = .paused
        state.pauseResumeDate = Date().addingTimeInterval(duration.interval)
        locationManager.stopMonitoring()
        schedulePauseResume(after: duration.interval)
        persist()
    }

    func resumeTracking() {
        state.status = .active
        state.pauseResumeDate = nil
        pauseTimer?.invalidate()
        locationManager.startMonitoring()
        persist()
    }

    // MARK: - Private

    private func schedulePauseResume(after interval: TimeInterval) {
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.resumeTracking()
        }
    }

    private func checkPauseExpiry() {
        if state.status == .paused, let resumeDate = state.pauseResumeDate {
            if Date() >= resumeDate {
                resumeTracking()
            } else {
                let remaining = resumeDate.timeIntervalSince(Date())
                schedulePauseResume(after: remaining)
                locationManager.stopMonitoring()
            }
        } else if state.status == .active {
            locationManager.startMonitoring()
        }
    }

    private func persist() {
        settings.trackingState = state
    }
}
