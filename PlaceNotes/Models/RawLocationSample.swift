import Foundation
import SwiftData

@Model final class RawLocationSample {
    var id: UUID
    var latitude: Double
    var longitude: Double
    var timestamp: Date
    var horizontalAccuracy: Double
    var speed: Double
    var altitude: Double?
    var verticalAccuracy: Double?
    var course: Double?
    var filterStatus: String
    var motionActivity: String?

    init(
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        horizontalAccuracy: Double,
        speed: Double,
        altitude: Double? = nil,
        verticalAccuracy: Double? = nil,
        course: Double? = nil,
        filterStatus: String,
        motionActivity: String? = nil
    ) {
        self.id = UUID()
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.altitude = altitude
        self.verticalAccuracy = verticalAccuracy
        self.course = course
        self.filterStatus = filterStatus
        self.motionActivity = motionActivity
    }
}
