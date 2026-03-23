import Foundation

enum TrackingStatus: String, Codable {
    case active
    case disabled
    case paused
}

struct TrackingState: Codable {
    var status: TrackingStatus
    var pauseResumeDate: Date?

    var isPaused: Bool {
        guard status == .paused, let resumeDate = pauseResumeDate else {
            return false
        }
        return Date() < resumeDate
    }

    var isTracking: Bool {
        status == .active || (status == .paused && !isPaused)
    }

    var pauseTimeRemaining: TimeInterval? {
        guard isPaused, let resumeDate = pauseResumeDate else { return nil }
        return resumeDate.timeIntervalSince(Date())
    }

    static let `default` = TrackingState(status: .disabled, pauseResumeDate: nil)
}

enum PauseDuration: CaseIterable {
    case oneHour
    case fourHours
    case twentyFourHours

    var interval: TimeInterval {
        switch self {
        case .oneHour: return 3600
        case .fourHours: return 14400
        case .twentyFourHours: return 86400
        }
    }

    var label: String {
        switch self {
        case .oneHour: return "1 Hour"
        case .fourHours: return "4 Hours"
        case .twentyFourHours: return "24 Hours"
        }
    }
}
