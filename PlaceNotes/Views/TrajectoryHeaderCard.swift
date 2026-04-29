import SwiftUI

struct TrajectoryHeaderCard: View {
    let day: Date
    let stats: TrajectoryStats?
    let isPathAvailable: Bool

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()

    private static let distanceFormatter: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.unitOptions = .naturalScale
        f.numberFormatter.maximumFractionDigits = 1
        f.numberFormatter.minimumFractionDigits = 0
        return f
    }()

    private var dayString: String {
        Self.dayFormatter.string(from: day)
    }

    private var distanceString: String {
        guard let meters = stats?.totalDistanceMeters else { return "—" }
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        return Self.distanceFormatter.string(from: measurement)
    }

    private var summaryString: String {
        guard let stats else { return "" }
        return "\(stats.placeCount) places · \(stats.rawSampleCount) samples"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dayString)
                .font(.subheadline.bold())
            HStack(spacing: 8) {
                if isPathAvailable {
                    Text(distanceString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(summaryString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Path data not available for this day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if isPathAvailable {
                Text("AM → PM")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }
}
