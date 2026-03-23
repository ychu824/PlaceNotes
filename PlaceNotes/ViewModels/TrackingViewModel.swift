import Foundation
import Combine

@MainActor
final class TrackingViewModel: ObservableObject {
    let trackingManager: TrackingManager

    @Published var statusText: String = ""
    @Published var pauseTimeRemainingText: String?

    private var cancellables = Set<AnyCancellable>()
    private var displayTimer: Timer?

    init(trackingManager: TrackingManager) {
        self.trackingManager = trackingManager

        trackingManager.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.updateStatusText(state)
            }
            .store(in: &cancellables)

        startDisplayTimer()
    }

    func enable() {
        trackingManager.enableTracking()
    }

    func disable() {
        trackingManager.disableTracking()
    }

    func pause(for duration: PauseDuration) {
        trackingManager.pauseTracking(for: duration)
    }

    func resume() {
        trackingManager.resumeTracking()
    }

    // MARK: - Private

    private func startDisplayTimer() {
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusText(self?.trackingManager.state ?? .default)
            }
        }
    }

    private func updateStatusText(_ state: TrackingState) {
        switch state.status {
        case .active:
            statusText = "Tracking Active"
            pauseTimeRemainingText = nil
        case .disabled:
            statusText = "Tracking Disabled"
            pauseTimeRemainingText = nil
        case .paused:
            if let remaining = state.pauseTimeRemaining, remaining > 0 {
                statusText = "Tracking Paused"
                pauseTimeRemainingText = formatTimeRemaining(remaining)
            } else {
                statusText = "Tracking Active"
                pauseTimeRemainingText = nil
            }
        }
    }

    private func formatTimeRemaining(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        if hours > 0 {
            return String(format: "Resumes in %dh %02dm", hours, minutes)
        } else {
            return String(format: "Resumes in %dm %02ds", minutes, seconds)
        }
    }
}
