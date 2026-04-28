import SwiftUI
import MapKit

struct TrajectoryPolyline: MapContent {
    let segments: [TrajectorySegment]
    let colorMode: TrajectoryColorMode

    var body: some MapContent {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
            ForEach(0..<max(0, segment.points.count - 1), id: \.self) { i in
                let a = segment.points[i]
                let b = segment.points[i + 1]
                MapPolyline(coordinates: [a.coordinate, b.coordinate])
                    .stroke(color(for: a, b), style: StrokeStyle(
                        lineWidth: 4,
                        lineCap: .round,
                        lineJoin: .round
                    ))
            }
        }
    }

    private func color(for a: TrajectoryPoint, _ b: TrajectoryPoint) -> Color {
        switch colorMode {
        case .time:
            let mid = (a.normalizedTimeOfDay + b.normalizedTimeOfDay) / 2
            return Self.timeColor(normalized: mid)
        case .speed, .plain:
            return .accentColor
        }
    }

    /// Maps 0...1 → AM yellow → PM orange → evening purple.
    static func timeColor(normalized t: Double) -> Color {
        let clamped = min(1.0, max(0.0, t))
        let amYellow = (r: 251.0/255, g: 191.0/255, b: 36.0/255)   // #fbbf24
        let pmOrange = (r: 251.0/255, g: 146.0/255, b: 60.0/255)   // #fb923c
        let evePurple = (r: 124.0/255, g: 58.0/255, b: 237.0/255)  // #7c3aed
        if clamped < 0.5 {
            let t2 = clamped / 0.5
            return Color(
                red: amYellow.r + (pmOrange.r - amYellow.r) * t2,
                green: amYellow.g + (pmOrange.g - amYellow.g) * t2,
                blue: amYellow.b + (pmOrange.b - amYellow.b) * t2
            )
        } else {
            let t2 = (clamped - 0.5) / 0.5
            return Color(
                red: pmOrange.r + (evePurple.r - pmOrange.r) * t2,
                green: pmOrange.g + (evePurple.g - pmOrange.g) * t2,
                blue: pmOrange.b + (evePurple.b - pmOrange.b) * t2
            )
        }
    }
}
