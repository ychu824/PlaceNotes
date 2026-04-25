import Foundation
import CoreLocation
import os

private let logger = Logger(subsystem: "com.placenotes.app", category: "LocationOneShot")

protocol LocationOneShotProviding {
    func fetchOnce(timeout: TimeInterval) async -> CLLocation?
}

/// Wraps CLLocationManager.requestLocation() as an async call.
/// Returns nil on timeout, permission denial, or CL error — callers fall back.
@MainActor
final class LocationOneShot: NSObject, LocationOneShotProviding, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func fetchOnce(timeout: TimeInterval) async -> CLLocation? {
        // Guard: don't pile up concurrent requests.
        if continuation != nil {
            logger.warning("fetchOnce called while a previous request is still pending")
            return nil
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            self.continuation = cont
            self.manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.resume(with: nil)
            }
        }
    }

    private func resume(with location: CLLocation?) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: location)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.resume(with: locations.last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.warning("one-shot failed: \(error.localizedDescription)")
        Task { @MainActor in
            self.resume(with: nil)
        }
    }
}
