import Foundation

enum LocationExporter {
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func exportCSV(from samples: [RawLocationSample]) -> Data {
        var lines = ["id,latitude,longitude,timestamp,horizontalAccuracy,speed,altitude,verticalAccuracy,course,filterStatus,motionActivity"]

        for s in samples {
            let row: [String] = [
                s.id.uuidString,
                "\(s.latitude)",
                "\(s.longitude)",
                iso8601.string(from: s.timestamp),
                "\(s.horizontalAccuracy)",
                "\(s.speed)",
                s.altitude.map { "\($0)" } ?? "",
                s.verticalAccuracy.map { "\($0)" } ?? "",
                s.course.map { "\($0)" } ?? "",
                s.filterStatus,
                s.motionActivity ?? ""
            ]
            lines.append(row.joined(separator: ","))
        }

        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }
}
