import XCTest
@testable import PlaceNotes

final class TrackingStateTests: XCTestCase {

    // MARK: - Default State

    func testDefaultStateIsDisabled() {
        let state = TrackingState.default
        XCTAssertEqual(state.status, .disabled)
        XCTAssertNil(state.pauseResumeDate)
    }

    // MARK: - isPaused

    func testIsPausedWhenPausedWithFutureDate() {
        let state = TrackingState(
            status: .paused,
            pauseResumeDate: Date().addingTimeInterval(3600)
        )
        XCTAssertTrue(state.isPaused)
    }

    func testIsPausedFalseWhenPausedWithPastDate() {
        let state = TrackingState(
            status: .paused,
            pauseResumeDate: Date().addingTimeInterval(-3600)
        )
        XCTAssertFalse(state.isPaused)
    }

    func testIsPausedFalseWhenActive() {
        let state = TrackingState(status: .active, pauseResumeDate: nil)
        XCTAssertFalse(state.isPaused)
    }

    func testIsPausedFalseWhenDisabled() {
        let state = TrackingState(status: .disabled, pauseResumeDate: nil)
        XCTAssertFalse(state.isPaused)
    }

    func testIsPausedFalseWhenPausedWithNoDate() {
        let state = TrackingState(status: .paused, pauseResumeDate: nil)
        XCTAssertFalse(state.isPaused)
    }

    // MARK: - isTracking

    func testIsTrackingWhenActive() {
        let state = TrackingState(status: .active, pauseResumeDate: nil)
        XCTAssertTrue(state.isTracking)
    }

    func testIsTrackingFalseWhenDisabled() {
        let state = TrackingState(status: .disabled, pauseResumeDate: nil)
        XCTAssertFalse(state.isTracking)
    }

    func testIsTrackingFalseWhenPausedWithFutureDate() {
        let state = TrackingState(
            status: .paused,
            pauseResumeDate: Date().addingTimeInterval(3600)
        )
        XCTAssertFalse(state.isTracking)
    }

    func testIsTrackingTrueWhenPauseExpired() {
        let state = TrackingState(
            status: .paused,
            pauseResumeDate: Date().addingTimeInterval(-3600)
        )
        XCTAssertTrue(state.isTracking)
    }

    // MARK: - pauseTimeRemaining

    func testPauseTimeRemainingWhenPaused() {
        let resumeDate = Date().addingTimeInterval(1800) // 30 min
        let state = TrackingState(status: .paused, pauseResumeDate: resumeDate)
        let remaining = state.pauseTimeRemaining
        XCTAssertNotNil(remaining)
        XCTAssertGreaterThan(remaining!, 1700)
        XCTAssertLessThanOrEqual(remaining!, 1800)
    }

    func testPauseTimeRemainingNilWhenActive() {
        let state = TrackingState(status: .active, pauseResumeDate: nil)
        XCTAssertNil(state.pauseTimeRemaining)
    }

    func testPauseTimeRemainingNilWhenExpired() {
        let state = TrackingState(
            status: .paused,
            pauseResumeDate: Date().addingTimeInterval(-100)
        )
        XCTAssertNil(state.pauseTimeRemaining)
    }

    // MARK: - PauseDuration

    func testPauseDurationIntervals() {
        XCTAssertEqual(PauseDuration.oneHour.interval, 3600)
        XCTAssertEqual(PauseDuration.fourHours.interval, 14400)
        XCTAssertEqual(PauseDuration.twentyFourHours.interval, 86400)
    }

    func testPauseDurationLabels() {
        XCTAssertEqual(PauseDuration.oneHour.label, "1 Hour")
        XCTAssertEqual(PauseDuration.fourHours.label, "4 Hours")
        XCTAssertEqual(PauseDuration.twentyFourHours.label, "24 Hours")
    }

    func testPauseDurationAllCasesCount() {
        XCTAssertEqual(PauseDuration.allCases.count, 3)
    }

    // MARK: - Codable

    func testTrackingStateEncodeDecode() throws {
        let original = TrackingState(
            status: .paused,
            pauseResumeDate: Date(timeIntervalSince1970: 1700000000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TrackingState.self, from: data)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.pauseResumeDate, original.pauseResumeDate)
    }
}
